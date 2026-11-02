#!/usr/bin/env bash
# Table tests for the version and tag selection in xs-sync.sh and its small
# pure helpers. No network, no GitHub token. Run: .github/scripts/xs-sync-test.sh
# shellcheck disable=SC2046,SC2086,SC2154,SC2249,SC2310,SC2317,SC2329 # word splitting of tag lists and mock functions are intended
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export XS_SYNC_SOURCE_ONLY=1
# shellcheck source=/dev/null
source "${here}/xs-sync.sh"
set +e

fail=0
pass=0

# expect <name> <want> <got>
expect() {
  if [[ "$2" == "$3" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"
  fi
}

# Mocks for the engine lookup: an appVersion per chart tag, a highest released N per
# engine and appVersion. xs_pick calls these two functions and nothing else.
# shellcheck disable=SC2034 # read by the mock functions
declare -A APP=([loki-19.4.0]=3.7.0 [loki-20.0.0]=3.7.5 [loki-20.1.0]=3.7.9 [loki-20.2.0]=3.7.9 [loki-20.2.1]=3.7.9
  [loki-20.3.0]=3.8.0 [loki-20.4.0]=3.8.1 [loki-20.10.0]=3.8.2 [loki-20.9.0]=3.8.1
  [tempo-distributed-3.17.0]=3.1.0 [tempo-distributed-3.17.1]=3.1.1 [tempo-distributed-3.18.0]=3.2.0)
declare -A REL=()
xs_chart_app() { printf '%s\n' "${APP[$2]:-}"; }
xs_engine_n() { if [[ -n "${REL[$1:$2]:-}" ]]; then printf '%s sha256:abc\n' "${REL[$1:$2]}"; fi; }

tags="loki-19.4.0 loki-20.0.0 loki-20.1.0 loki-20.2.0 loki-20.2.1 loki-20.3.0 loki-20.3.0-rc.1 loki-6.24.0-weekly.232 loki-canary-1.0.0 loki-stack-2.0.0 tempo-distributed-3.17.0 tempo-distributed-3.17.1 tempo-distributed-3.18.0 grafana-12.0.0"

has() { if [[ "$1" == *"$2"* ]]; then echo yes; else echo no; fi; }
# pick <chart> <current> [cap]: "<target>|<engine>|<skipped>"
pick() {
  local chart="$1" cur="$2" r
  shift 2
  r="$(printf '%s\n' ${TAGS:-${tags}} | xs_pick "${chart}" "${cur}" "$@" 2>&1)" || { echo "error: ${r}"; return; }
  printf '%s|%s|%s\n' "$(grep '^target=' <<<"${r}" | cut -d= -f2)" "$(grep '^engine=' <<<"${r}" | cut -d= -f2)" "$(grep '^skipped=' <<<"${r}" | cut -d= -f2)"
}

# nothing is released: stay, and say which tags were skipped for lack of an engine
REL=()
expect "no engine anywhere" "||loki-20.3.0 loki-20.2.1 loki-20.2.0" "$(pick loki loki-20.1.0)"
expect "no newer tag" "||" "$(pick tempo-distributed tempo-distributed-3.18.0)"
# the engine for the newest app is not released: fall back to the newest tag that has one
REL=([loki:3.7.9]=0)
expect "older tag with engine" "loki-20.2.1|3.7.9-xs.0|loki-20.3.0" "$(pick loki loki-20.1.0)"
# same appVersion as current, engine released: a newer chart tag is still a bump
expect "chart patch bump" "loki-20.2.1|3.7.9-xs.0|loki-20.3.0" "$(pick loki loki-20.1.0)"
expect "already on the target" "||loki-20.3.0" "$(pick loki loki-20.2.1)"
# newest tag has its engine: it wins and nothing is skipped
REL=([loki:3.7.9]=0 [loki:3.8.0]=1)
expect "newest wins, highest N" "loki-20.3.0|3.8.0-xs.1|" "$(pick loki loki-20.1.0)"
# numeric ordering of chart versions
REL=([loki:3.8.1]=0 [loki:3.8.2]=3)
expect "20.10.0 above 20.9.0" "loki-20.10.0|3.8.2-xs.3|" "$(TAGS="${tags} loki-20.4.0 loki-20.9.0 loki-20.10.0" pick loki loki-20.2.1)"
# a cap hides newer tags
expect "cap" "loki-20.4.0|3.8.1-xs.0|" "$(TAGS="${tags} loki-20.4.0 loki-20.9.0 loki-20.10.0" pick loki loki-20.2.1 --cap loki-20.4.0)"
# tags of other charts and rc, weekly and canary tags never match
REL=([loki:3.7.9]=0 [tempo:3.2.0]=0)
expect "other chart tags ignored" "||" "$(pick tempo-distributed tempo-distributed-3.18.0)"
expect "tempo bump" "tempo-distributed-3.18.0|3.2.0-xs.0|" "$(pick tempo-distributed tempo-distributed-3.17.1)"
expect "rc ignored" "||loki-20.3.0" "$(pick loki loki-20.2.1)"
expect "bad current" "error: ::error::current tag loki-20.1.0+xs.0 is not a stable loki chart tag" "$(pick loki loki-20.1.0+xs.0)"
expect "wrong chart current" "error: ::error::current tag tempo-distributed-3.17.1 is not a stable loki chart tag" "$(pick loki tempo-distributed-3.17.1)"
REL=()

# head and decision
expect "head one" "sync/loki-20.2.1" "$(xs_head loki-20.2.1)"
expect "head two" "sync/loki-20.2.1_tempo-distributed-3.18.0" "$(xs_head loki-20.2.1 tempo-distributed-3.18.0)"
expect "head rebuild" "sync/loki-20.1.0-xs.1-e2" "$(xs_head loki-20.1.0-xs.1-e2)"
bot() { if xs_bot_head "$1"; then echo yes; else echo no; fi; }
for h in sync/loki-20.2.1 sync/loki-20.1.0-xs.1-e2 sync/loki-20.2.1_tempo-distributed-3.18.0 sync/upstream-20261102 sync/tempo-distributed-3.17.1-xs.12-e30; do
  expect "bot head ${h}" yes "$(bot "${h}")"
done
for h in sync/loki-20.2.1-fix sync/loki-20.2.1-xs.1 sync/loki-20.2.1-xs.1-e sync/fix-loki sync/upstream-1 sync/upstream-20261102-x sync/mimir-3.2.3 sync/loki-20.2.1_ sync/ main 'sync/loki-20.2.1;rm' sync/loki-20.2; do
  expect "not a bot head ${h}" no "$(bot "${h}")"
done
CUR="loki=20.1.0.0.0 tempo-distributed=3.17.1.0.0"
dec() { # <head> [open heads...] -> "proceed [supersede]"
  local r
  r="$(xs_decide "$1" "${CUR}" "${@:2}")"
  printf '%s [%s]\n' "$(grep '^proceed=' <<<"${r}" | cut -d= -f2)" "$(grep '^supersede=' <<<"${r}" | cut -d= -f2)"
}
expect "decide new" "true []" "$(dec sync/loki-20.2.1)"
expect "decide nothing" "false []" "$(dec '')"
expect "decide open pr" "false []" "$(dec sync/loki-20.2.1 sync/loki-20.2.1)"
expect "decide supersede a lower head" "true [sync/loki-20.2.0]" "$(dec sync/loki-20.2.1 sync/loki-20.2.0)"
expect "decide supersede, pr open" "false [sync/loki-20.2.0]" "$(dec sync/loki-20.2.1 sync/loki-20.2.0 sync/loki-20.2.1)"
expect "no new head leaves open PRs alone" "false []" "$(dec '' sync/loki-20.2.0)"
expect "other heads" "true []" "$(dec sync/loki-20.2.1 feature/x dependabot/foo)"
expect "odd head" "true []" "$(dec sync/loki-20.2.1 'sync/loki;rm' 'sync/')"
# human branches under sync/ are never touched
expect "human fix branch kept" "true []" "$(dec sync/loki-20.2.1 sync/loki-20.2.0-fix sync/fix-loki sync/loki-20.2.1-wip)"
# a head above the new target is not superseded
expect "higher head kept" "true []" "$(dec sync/loki-20.2.0 sync/loki-20.2.1)"
# the new head covers the old one only when every chart in it is covered
expect "combined head covers a single-chart head" "true [sync/loki-20.2.1]" "$(dec sync/loki-20.2.1_tempo-distributed-3.18.0 sync/loki-20.2.1)"
expect "single-chart head does not cover a combined one" "true []" "$(dec sync/loki-20.2.1 sync/loki-20.2.1_tempo-distributed-3.18.0)"
# rebuild heads: a newer engine build supersedes the open rebuild, an older one does not
expect "newer N supersedes the open rebuild" "true [sync/loki-20.1.0-xs.1-e1]" "$(dec sync/loki-20.1.0-xs.1-e2 sync/loki-20.1.0-xs.1-e1)"
expect "same N is already open" "false []" "$(dec sync/loki-20.1.0-xs.1-e2 sync/loki-20.1.0-xs.1-e2)"
expect "older N does not supersede" "true []" "$(dec sync/loki-20.1.0-xs.1-e1 sync/loki-20.1.0-xs.1-e2)"
expect "a chart bump supersedes an open rebuild" "true [sync/loki-20.1.0-xs.1-e2]" "$(dec sync/loki-20.2.1 sync/loki-20.1.0-xs.1-e2)"
# a head for a chart the new head does not carry is superseded only when main is already past it
expect "head of another chart is kept" "true []" "$(dec sync/loki-20.2.1 sync/tempo-distributed-3.18.0)"
expect "head already reached by main is superseded" "true [sync/tempo-distributed-3.17.1]" "$(dec sync/loki-20.2.1 sync/tempo-distributed-3.17.1)"
# upstream-only refreshes
expect "upstream head is superseded by a chart head" "true [sync/upstream-20261001]" "$(dec sync/loki-20.2.1 sync/upstream-20261001)"
expect "second upstream refresh is not opened" "false []" "$(dec sync/upstream-20261102 sync/upstream-20261001)"
r="$(xs_decide sync/upstream-20261102 "${CUR}" sync/upstream-20261001)"
expect "the open upstream refresh is refreshed in place" "sync/upstream-20261001 true" "$(grep '^head=' <<<"${r}" | cut -d= -f2) $(grep '^open_pr=' <<<"${r}" | cut -d= -f2)"
r="$(xs_decide sync/loki-20.2.1 "${CUR}" sync/loki-20.2.1)"
expect "open_pr for an open head" "true false" "$(grep '^open_pr=' <<<"${r}" | cut -d= -f2) $(grep '^proceed=' <<<"${r}" | cut -d= -f2)"
expect "upstream refresh does not supersede a chart head" "true []" "$(dec sync/upstream-20261102 sync/loki-20.2.1)"
# keys
xs_key_gt 20.1.0.1.2 20.1.0.1.1 && r=yes || r=no
expect "key e" yes "${r}"
xs_key_gt 20.1.0.1.9 20.1.0.2.0 && r=yes || r=no
expect "key m before e" no "${r}"
xs_key_gt 20.10.0.0.0 20.9.9.9.9 && r=yes || r=no
expect "key numeric" yes "${r}"

# The registry lookup with fake gh, crane and cosign. Tags are mutable, so the digest is
# resolved and verified (signature and provenance attestation, exact identity); a package
# that is absent is told from one that is denied by the Packages API.
unset -f xs_chart_app xs_engine_n
# shellcheck source=/dev/null
XS_SYNC_SOURCE_ONLY=1 source "${here}/xs-sync.sh"
set +e
CRANE_TAGS="" CRANE_ERR="" COSIGN_OK="" COSIGN_ERR="" ATTEST_OK="" ATTEST_ERR="" PKG_ERR="" CRANE_CALLS="$(mktemp)"
: > "${CRANE_CALLS}"
gh() {
  case "$1" in
    api) if [[ -n "${PKG_ERR}" ]]; then echo "${PKG_ERR}" >&2; return 1; fi; echo '{"name":"x"}' ;;
    attestation)
      local ref="" id="" a
      shift
      while (($#)); do
        case "$1" in
          verify) shift ;;
          --repo) shift 2 ;;
          --cert-identity) id="$2"; shift 2 ;;
          *) a="$1"; shift ;;
        esac
      done
      ref="${a}"
      [[ "${id}" == "https://github.com/xscaler/loki/.github/workflows/xs-release.yml@refs/heads/main" ]] || { echo 'Error: verifying with issuer "sigstore.dev"' >&2; return 1; }
      if [[ -n "${ATTEST_ERR}" ]]; then echo "${ATTEST_ERR}" >&2; return 1; fi
      case " ${ATTEST_OK} " in *" ${ref##*@sha256:d-} "*) return 0 ;; esac
      echo "Error: no attestations found" >&2
      return 1
      ;;
  esac
}
crane() {
  echo "$1" >> "${CRANE_CALLS}"
  case "$1" in
    ls) if [[ -n "${CRANE_ERR}" ]]; then echo "${CRANE_ERR}" >&2; return 1; fi; printf '%s\n' ${CRANE_TAGS} ;;
    digest) echo "sha256:d-${2##*-xs.}" ;;
  esac
}
cosign() {
  # the last argument is <repo>@sha256:d-<N>, the identity is passed with --certificate-identity
  local id="" ref="" a
  while (($#)); do
    case "$1" in
      --certificate-identity) id="$2"; shift 2 ;;
      --certificate-oidc-issuer) shift 2 ;;
      *) a="$1"; shift ;;
    esac
  done
  ref="${a}"
  [[ "${id}" == "https://github.com/xscaler/loki/.github/workflows/xs-release.yml@refs/heads/main" ]] || { echo "error: none of the expected identities matched" >&2; return 1; }
  if [[ -n "${COSIGN_ERR}" ]]; then echo "${COSIGN_ERR}" >&2; return 1; fi
  case " ${COSIGN_OK} " in *" ${ref##*@sha256:d-} "*) return 0 ;; esac
  echo "Error: no signatures found" >&2
  return 1
}
live() { (xs_engine_live "$@" 2>&1); }
CRANE_TAGS="3.7.9-xs.0 3.7.9-xs.1 3.7.9-xs.2 3.7.9-xs.10 3.7.9 3.7.9-xs.1-rc 3.7.90-xs.0 latest sha256-abc"
COSIGN_OK="0 1 10" ATTEST_OK="0 1 10"
expect "live highest verified, numeric, with its digest" "10 sha256:d-10" "$(live loki 3.7.9 | tail -n1)"
ATTEST_OK="0 1"
expect "live skips an unattested N" "1 sha256:d-1" "$(live loki 3.7.9 | tail -n1)"
COSIGN_OK="0"
expect "live skips an unsigned N" "0 sha256:d-0" "$(live loki 3.7.9 | tail -n1)"
COSIGN_OK="" ATTEST_OK=""
expect "live none verified" "" "$(live loki 3.7.9 | grep -v 'is not signed and attested')"
COSIGN_OK="0 1 10" ATTEST_OK="0 1 10"
CRANE_TAGS="3.8.0-xs.0"
expect "live other appVersion" "" "$(live loki 3.7.9)"
CRANE_TAGS="3.7.9-xs.0"
# absent is a 404 from the Packages API, nothing else
PKG_ERR="gh: Not Found (HTTP 404)"
expect "live package absent" "no package ghcr.io/xscaler/loki yet" "$(live loki 3.7.9)"
PKG_ERR="gh: Resource not accessible by integration (HTTP 403)"
expect "live package denied fails" "yes" "$(has "$(live loki 3.7.9)" 'could not look up the package')"
PKG_ERR="gh: API rate limit exceeded (HTTP 429)"
expect "live package rate limit fails" "yes" "$(has "$(live loki 3.7.9)" 'could not look up the package')"
PKG_ERR=""
CRANE_ERR="DENIED: requested access to the resource is denied"
expect "live registry denied fails" "yes" "$(has "$(live loki 3.7.9)" 'could not list')"
CRANE_ERR="TOOMANYREQUESTS: rate limit"
expect "live registry rate limit fails" "yes" "$(has "$(live loki 3.7.9)" 'could not list')"
CRANE_ERR="Get https://ghcr.io: dial tcp: i/o timeout"
expect "live registry error fails" "yes" "$(has "$(live loki 3.7.9)" 'could not list')"
CRANE_ERR="" COSIGN_ERR="Error: rekor unavailable"
expect "live cosign infra error fails" "yes" "$(has "$(live loki 3.7.9)" 'cosign verify of')"
COSIGN_ERR="" ATTEST_ERR="Error: dial tcp: i/o timeout"
expect "live attestation infra error fails" "yes" "$(has "$(live loki 3.7.9)" 'attestation verify of')"
ATTEST_ERR=""
expect "live foreign identity is not a release" "" "$(live tempo 3.7.9 | grep -v 'is not signed and attested')"

# lookups are cached per engine and appVersion within a run
XS_ENGINE_CACHE="$(mktemp -d)"
export XS_ENGINE_CACHE
: > "${CRANE_CALLS}"
r1="$(xs_engine_n loki 3.7.9)"
r2="$(xs_engine_n loki 3.7.9)"
expect "cached lookup result" "0 sha256:d-0|0 sha256:d-0" "${r1}|${r2}"
expect "one registry listing for two lookups" "1" "$(grep -c '^ls$' "${CRANE_CALLS}")"
CRANE_TAGS="" 
xs_engine_n loki 3.8.0 > /dev/null
expect "another appVersion is another lookup" "2" "$(grep -c '^ls$' "${CRANE_CALLS}")"
# an empty result is cached too
xs_engine_n loki 3.8.0 > /dev/null
expect "an empty lookup is cached" "2" "$(grep -c '^ls$' "${CRANE_CALLS}")"
unset -f crane cosign gh

# The mock is honoured only when the rehearsal switches it on.
r="$(XS_ENGINE_MOCK="loki:3.7.9:0" XS_MOCK_OK=1 xs_engine_n loki 3.7.9)"
expect "mock on" "0 sha256:0000000000000000000000000000000000000000000000000000000000000000" "${r}"
r="$(XS_ENGINE_MOCK="" XS_MOCK_OK=1 xs_engine_n loki 3.7.9)"
expect "mock empty" "" "${r}"
gh() { echo "gh: Not Found (HTTP 404)" >&2; return 1; }
r="$(XS_ENGINE_CACHE="$(mktemp -d)" XS_ENGINE_MOCK="loki:3.7.9:0" xs_engine_n loki 3.7.9 2>&1)"
expect "mock ignored without the switch" "no package ghcr.io/xscaler/loki yet" "${r}"
unset -f gh

# version and tag helpers
expect "version" "3.7.9" "$(xs_version_of v3.7.9)"
expect "version rc" "" "$(xs_version_of v3.7.9-rc.1)"
expect "version newline" "" "$(xs_version_of $'v3.7.9\nx')"
expect "tag of" "v3.7.9" "$(xs_tag_of 3.7.9)"
xs_ver_gt 3.7.10 3.7.9 && r=yes || r=no
expect "gt 3.7.10 3.7.9" "yes" "${r}"
xs_ver_gt 3.7.9 3.7.9 && r=yes || r=no
expect "gt equal" "no" "${r}"
xs_ver_gt 3.10.0 3.9.9 && r=yes || r=no
expect "gt minor numeric" "yes" "${r}"
xs_ver_gt 2.9.20 3.0.0 && r=yes || r=no
expect "gt major" "no" "${r}"

# patch path rules
for p in .github/workflows/xs-charts.yml .github/scripts/xs-sync.sh .github/actions/xs-tools/action.yml; do
  xs_path_allowed "${p}" && r=yes || r=no
  expect "allowed ${p}" "yes" "${r}"
done
for p in .github/workflows/ci.yaml .github/scripts/other.sh .github/actions/setup/action.yml charts/loki/Chart.yaml README.md; do
  xs_path_allowed "${p}" && r=yes || r=no
  expect "not allowed ${p}" "no" "${r}"
done

# flag names from help output
tmp="$(mktemp -d)"
printf 'Usage of x:\n  -a.b\n    \tdoc -not-a-flag\n  -c value\n    \tdoc\n  -a.b\n' > "${tmp}/h"
expect "flag names" "$(printf -- '-a.b\n-c')" "$(flag_names "${tmp}/h")"
rm -rf "${tmp}"

# body fill
tmp="$(mktemp -d)"
printf 'head\n%s\nPending\n%s\ntail\n' "${XS_FLAG_BEGIN}" "${XS_FLAG_END}" > "${tmp}/body"
printf 'line 1\nline 2\n' > "${tmp}/fill"
expect "body fill" "$(printf 'head\n%s\nline 1\nline 2\n%s\ntail' "${XS_FLAG_BEGIN}" "${XS_FLAG_END}")" "$(xs_body_fill "${tmp}/body" "${tmp}/fill")"
xs_body_fill "${tmp}/body" "${tmp}/fill" > "${tmp}/body2"
printf 'new\n' > "${tmp}/fill2"
expect "body refill" "$(printf 'head\n%s\nnew\n%s\ntail' "${XS_FLAG_BEGIN}" "${XS_FLAG_END}")" "$(xs_body_fill "${tmp}/body2" "${tmp}/fill2")"
rm -rf "${tmp}"

# ---------------------------------------------------------------------------
# Helpers that need no repository
# ---------------------------------------------------------------------------
expect "own heads" "$(printf 'sync/loki-20.2.1\nfeature/x')" "$(printf '%s' '[{"headRefName":"sync/loki-20.2.1","isCrossRepository":false},{"headRefName":"sync/loki-9.9.9","isCrossRepository":true},{"headRefName":"feature/x","isCrossRepository":false}]' | xs_own_heads)"
# a fork PR named like ours is not counted: nothing superseded, nothing open
expect "fork pr ignored" "true []" "$(dec sync/loki-20.2.1 $(printf '%s' '[{"headRefName":"sync/loki-20.2.1","isCrossRepository":true}]' | xs_own_heads))"

expect "md paths" "$(printf -- "- \`a b\`\n- \`x'y\`\n- \`l1?l2\`")" "$(printf 'a b\0x`y\0l1\nl2\0' | xs_md_paths)"
expect "plain paths" "- @types/x" "$(printf '@types/x\0' | xs_md_paths plain)"

# retry with backoff on throttling, no retry on other errors
cf="$(mktemp)"
echo 0 > "${cf}"
gh() {
  local calls
  calls=$(($(cat "${cf}") + 1))
  echo "${calls}" > "${cf}"
  if ((calls <= 2)); then echo "gh: HTTP 429 You have exceeded a secondary rate limit" >&2; return 1; fi
  echo '{"sha":"abc"}'
}
echo '{}' > /tmp/xs-test-empty.json
XS_RETRY_SLEEP=0 api_call POST repos/x/y/git/blobs /tmp/xs-test-empty.json > /tmp/xs-test-out 2>&1
expect "retry throttled" "3 {\"sha\":\"abc\"}" "$(cat "${cf}") $(tail -n1 /tmp/xs-test-out)"
echo 0 > "${cf}"
gh() { echo $(($(cat "${cf}") + 1)) > "${cf}"; echo "gh: Not Found (HTTP 404)" >&2; return 1; }
XS_RETRY_SLEEP=0 api_call POST repos/x/y/git/blobs /tmp/xs-test-empty.json > /dev/null 2>&1
rc=$?
expect "no retry on 404" "1 1" "$(cat "${cf}") ${rc}"
unset -f gh
rm -f /tmp/xs-test-empty.json /tmp/xs-test-out "${cf}"

# ---------------------------------------------------------------------------
# Scratch repositories
# ---------------------------------------------------------------------------
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT

# in <repo> <command...>: run in the repository, output and status in OUT and RC.
in_repo() {
  local d="$1"
  shift
  OUT="$(cd "${d}" && "$@" 2>&1)"
  RC=$?
}
G() { git -C "${repo}" "$@"; }

# A chart repository: upstream main with two charts, chart tags, and main = upstream
# plus our patch set. The chart tags sit on upstream commits that are older than the
# upstream main tip, as in the real repository.
repo="${scratch}/h"
git init -q -b up "${repo}"
lines() { local i; for ((i = 1; i <= $2; i++)); do printf '%s %s\n' "$1" "${i}"; done; }
mkchart() { # <chart> <version> <app>
  mkdir -p "${repo}/charts/$1/templates" "${repo}/charts/$1/tests"
  printf 'apiVersion: v2\nname: %s\nappVersion: %s\nversion: %s\n' "$1" "$3" "$2" > "${repo}/charts/$1/Chart.yaml"
  { lines "# values" 10; echo '  repository: grafana/x'; lines "# values" 30; } > "${repo}/charts/$1/values.yaml"
  lines "# tpl" 40 > "${repo}/charts/$1/templates/_h.tpl"
}
mkchart loki 1.0.0 1.0.0
mkchart tempo-distributed 1.0.0 1.0.0
mkdir -p "${repo}/charts/other" "${repo}/.github/workflows"
echo one > "${repo}/README.md"
echo one > "${repo}/charts/other/a.txt"
echo one > "${repo}/.github/workflows/ci.yaml"
G add -A && G commit -q -m u0 && G tag loki-1.0.0 && G tag tempo-distributed-1.0.0
u0="$(G rev-parse HEAD)"

# main: u0 plus the patch set
G checkout -q -b main
for c in loki tempo-distributed; do
  e="${c%%-*}"
  d="${repo}/charts/${c}"
  sed -i "s/^version: 1.0.0\$/version: 1.0.0+xs.0/" "${d}/Chart.yaml"
  { printf 'xscaler:\n  engineTag: 1.0.0-xs.0\n'; sed "s#grafana/x#xscaler/${e}#" "${d}/values.yaml"; } > "${d}/v" && mv "${d}/v" "${d}/values.yaml"
  sed -i '5s/.*/# xs patched line/' "${d}/templates/_h.tpl"
  printf 'image: ghcr.io/xscaler/%s:1.0.0-xs.0\nversion: "1.0.0"\nversion2: 1.0.0-xs.1\nother: 11.0.0\n' "${e}" > "${d}/tests/xs_image_test.yaml"
done
echo p > "${repo}/.github/workflows/xs-charts.yml"
G add -A && G commit -q -m patch
G checkout -q up

# upstream moves on: other files, new chart releases 1.1.0, then more upstream main
echo two > "${repo}/README.md"
echo two > "${repo}/charts/other/a.txt"
echo two > "${repo}/.github/workflows/ci.yaml"
sed -i '30s/.*/# upstream edit/' "${repo}/charts/loki/templates/_h.tpl"
sed -i '30s/.*/# upstream edit/' "${repo}/charts/tempo-distributed/templates/_h.tpl"
sed -i 's/^appVersion: .*/appVersion: 2.0.0/; s/^version: .*/version: 1.1.0/' "${repo}/charts/loki/Chart.yaml"
sed -i 's/^appVersion: .*/appVersion: 3.0.0/; s/^version: .*/version: 1.1.0/' "${repo}/charts/tempo-distributed/Chart.yaml"
echo '# new upstream value' >> "${repo}/charts/loki/values.yaml"
G add -A && G commit -q -m u1 && G tag loki-1.1.0 && G tag tempo-distributed-1.1.0 && G tag loki-1.2.0-rc.1
echo three > "${repo}/README.md"
G commit -q -am u2
u2="$(G rev-parse HEAD)"
# a chart tag whose appVersion is below main's: never a target
G checkout -q -b down "${u0}"
sed -i 's/^appVersion: .*/appVersion: 0.9.0/; s/^version: .*/version: 1.3.0/' "${repo}/charts/loki/Chart.yaml"
G commit -q -am down && G tag loki-1.3.0
G checkout -q up
G update-ref refs/remotes/origin/main main
G update-ref refs/remotes/origin/upstream/main up
G checkout -q main

REL=()
expect "older tags" "loki-1.0.0" "$(cd "${repo}" && older_tags loki loki-1.1.0)"
in_repo "${repo}" git tag --list 'loki-*'
expect "current tag from Chart.yaml" "loki-1.0.0 tempo-distributed-1.0.0" "$(cd "${repo}" && echo "$(chart_current_tag origin/main loki) $(chart_current_tag origin/main tempo-distributed)")"
expect "engine tag" "1.0.0-xs.0" "$(cd "${repo}" && chart_engine_tag origin/main loki)"

# detect: only loki has a released engine
export XS_MOCK_OK=1 XS_ENGINE_MOCK="loki:2.0.0:0"
in_repo "${repo}" cmd_detect --base origin/main
k() { grep "^$1=" <<<"${OUT}" | cut -d= -f2-; }
Z=sha256:0000000000000000000000000000000000000000000000000000000000000000
expect "detect bumps" "loki:loki-1.1.0:2.0.0-xs.0@${Z}" "$(k bumps)"
expect "detect head" "sync/loki-1.1.0" "$(k head)"
expect "detect proceed" "true" "$(k proceed)"
expect "detect upstream base" "${u0}" "$(k upstream_base)"
expect "detect upstream commit" "$(G rev-parse up)" "$(k upstream_commit)"
expect "detect notes the skipped chart" "yes" "$(grep -q 'tempo-distributed: stays at tempo-distributed-1.0.0, no released engine for tempo-distributed-1.1.0' <<<"${OUT}" && echo yes || echo no)"
XS_ENGINE_MOCK=""
in_repo "${repo}" cmd_detect --base origin/main
expect "detect nothing released" "false  " "$(k proceed) $(k bumps) $(k head)"
XS_ENGINE_MOCK="loki:2.0.0:0 tempo:3.0.0:2"
printf 'sync/loki-1.1.0\n' > "${scratch}/heads"
in_repo "${repo}" cmd_detect --base origin/main --open-heads "${scratch}/heads"
expect "detect both, stale pr superseded" "sync/loki-1.1.0_tempo-distributed-1.1.0 true sync/loki-1.1.0 loki:loki-1.1.0:2.0.0-xs.0@${Z} tempo-distributed:tempo-distributed-1.1.0:3.0.0-xs.2@${Z}" "$(k head) $(k proceed) $(k supersede) $(k bumps)"
in_repo "${repo}" cmd_detect --base origin/main --cap loki-1.0.0
expect "detect cap" "tempo-distributed:tempo-distributed-1.1.0:3.0.0-xs.2@${Z}" "$(k bumps)"

# appVersion downgrade: loki-1.3.0 carries 0.9.0, below main's 1.0.0, even with an engine released
XS_ENGINE_MOCK="loki:0.9.0:0 loki:2.0.0:0"
in_repo "${repo}" cmd_detect --base origin/main
expect "no downgrade target" "loki:loki-1.1.0:2.0.0-xs.0@${Z}" "$(k bumps)"
XS_ENGINE_MOCK="loki:0.9.0:0"
in_repo "${repo}" cmd_detect --base origin/main
expect "downgrade only: nothing" "false " "$(k proceed) $(k bumps)"
expect "downgrade is reported" "yes" "$(grep -q 'appVersion below 1.0.0 for loki-1.3.0' <<<"${OUT}" && echo yes || echo no)"

# upstream drift: no chart moves, main's base is behind upstream main
XS_ENGINE_MOCK=""
in_repo "${repo}" cmd_detect --base origin/main
expect "no drift under the thresholds" "false false" "$(k drift) $(k proceed)"
XS_DRIFT_COMMITS=1 XS_TODAY=20261102 in_repo "${repo}" cmd_detect --base origin/main
expect "drift by commits" "true sync/upstream-20261102 true" "$(k drift) $(k head) $(k proceed)"
XS_DRIFT_DAYS=-1 XS_TODAY=20261102 in_repo "${repo}" cmd_detect --base origin/main
expect "drift by days" "true sync/upstream-20261102" "$(k drift) $(k head)"
printf 'sync/upstream-20261001\n' > "${scratch}/heads"
XS_DRIFT_COMMITS=1 XS_TODAY=20261102 in_repo "${repo}" cmd_detect --base origin/main --open-heads "${scratch}/heads"
expect "an open upstream refresh blocks another" "true false" "$(k drift) $(k proceed)"
XS_DRIFT_COMMITS=1 XS_ENGINE_MOCK="loki:2.0.0:0" in_repo "${repo}" cmd_detect --base origin/main --open-heads "${scratch}/heads"
expect "a chart bump supersedes an upstream refresh" "sync/loki-1.1.0 sync/upstream-20261001" "$(k head) $(k supersede)"

# a newer engine build of the chart's own appVersion: a rebuild of the same chart tag
XS_ENGINE_MOCK="loki:1.0.0:2"
in_repo "${repo}" cmd_detect --base origin/main
expect "rebuild detected" "loki:loki-1.0.0:1.0.0-xs.2@${Z} sync/loki-1.0.0-xs.1-e2 true" "$(k bumps) $(k head) $(k proceed)"
expect "rebuild noted" "yes" "$(grep -q 'loki: loki-1.0.0 rebuilt as +xs.1 with engine 1.0.0-xs.2 (was 1.0.0-xs.0)' <<<"${OUT}" && echo yes || echo no)"
XS_ENGINE_MOCK="loki:1.0.0:0"
in_repo "${repo}" cmd_detect --base origin/main
expect "same engine build is no rebuild" "false " "$(k proceed) $(k bumps)"
XS_ENGINE_MOCK="loki:1.0.0:2 loki:2.0.0:0"
in_repo "${repo}" cmd_detect --base origin/main
expect "a chart bump wins over a rebuild" "loki:loki-1.1.0:2.0.0-xs.0@${Z}" "$(k bumps)"
XS_ENGINE_MOCK="loki:1.0.0:2 tempo:3.0.0:0"
in_repo "${repo}" cmd_detect --base origin/main
expect "rebuild and bump together" "sync/loki-1.0.0-xs.1-e2_tempo-distributed-1.1.0" "$(k head)"
XS_ENGINE_MOCK=""

# the build: both charts bumped, upstream main moved on
base_tree="$(G rev-parse 'main^{tree}')"
idx="${scratch}/idx"
specs=("loki|loki-1.0.0|loki-1.1.0|2.0.0-xs.0" "tempo-distributed|tempo-distributed-1.0.0|tempo-distributed-1.1.0|3.0.0-xs.2")
tree="$(cd "${repo}" && assemble_tree "${idx}" "${u2}" "${u0}" "${base_tree}" "${specs[@]}" 3> "${scratch}/conf")"
expect "assemble rc" "0" "$?"
T() { git -C "${repo}" show "${tree}:$1"; }
expect "chart version" "version: 1.1.0+xs.0" "$(T charts/loki/Chart.yaml | grep '^version')"
expect "chart appVersion" "appVersion: 2.0.0" "$(T charts/loki/Chart.yaml | grep '^appVersion')"
expect "engine tag" "  engineTag: 2.0.0-xs.0" "$(T charts/loki/values.yaml | grep engineTag)"
expect "repository kept" "  repository: xscaler/loki" "$(T charts/loki/values.yaml | grep repository)"
expect "upstream value kept" "# new upstream value" "$(T charts/loki/values.yaml | tail -n1)"
expect "3-way: both edits in the template" "# xs patched line|# upstream edit" "$(T charts/loki/templates/_h.tpl | sed -n -e '5p' -e '30p' | paste -sd'|')"
expect "test file follows the version" "image: ghcr.io/xscaler/loki:2.0.0-xs.0|version: \"2.0.0\"|version2: 1.0.0-xs.1|other: 11.0.0" "$(T charts/loki/tests/xs_image_test.yaml | paste -sd'|')"
expect "tempo engine N" "  engineTag: 3.0.0-xs.2" "$(T charts/tempo-distributed/values.yaml | grep engineTag)"
expect "other chart is upstream main" "$(G rev-parse "${u2}:charts/other")" "$(G rev-parse "${tree}:charts/other")"
expect "readme is upstream main" "three" "$(T README.md)"
expect "ci.yaml is upstream main" "two" "$(T .github/workflows/ci.yaml)"
expect "xs workflow carried" "p" "$(T .github/workflows/xs-charts.yml)"
# a chart without a bump is main's chart, untouched
specs1=("loki|loki-1.0.0|loki-1.1.0|2.0.0-xs.0" "tempo-distributed|||")
tree1="$(cd "${repo}" && assemble_tree "${scratch}/idx1" "${u2}" "${u0}" "${base_tree}" "${specs1[@]}" 3> "${scratch}/conf")"
expect "kept chart is main's" "$(G rev-parse "main:charts/tempo-distributed")" "$(G rev-parse "${tree1}:charts/tempo-distributed")"
# the same bump with no new upstream commits and a different engine N
tree2="$(cd "${repo}" && assemble_tree "${scratch}/idx2" "${u0}" "${u0}" "${base_tree}" "loki|loki-1.0.0|loki-1.1.0|2.0.0-xs.7" "tempo-distributed|||" 3> "${scratch}/conf")"
expect "engine N 7, README stays at u0" "  engineTag: 2.0.0-xs.7 one" "$(git -C "${repo}" show "${tree2}:charts/loki/values.yaml" | grep engineTag) $(git -C "${repo}" show "${tree2}:README.md")"
# engine tag of another appVersion is refused
in_repo "${repo}" assemble_tree "${scratch}/idx3" "${u2}" "${u0}" "${base_tree}" "loki|loki-1.0.0|loki-1.1.0|1.9.0-xs.0" 3> "${scratch}/conf"
expect "engine tag must match appVersion" "1 yes" "${RC} $(grep -q 'does not match appVersion' <<<"${OUT}" && echo yes || echo no)"

mk() { G -c user.name=t -c user.email=t@t commit-tree "$1" "${@:2}" -m sync; }
# the rebuild: same chart tags, version +xs.1 (and +xs.3 from +xs.2), engine tag and test file follow
rtree="$(cd "${repo}" && assemble_tree "${scratch}/idx5" "${u0}" "${u0}" "${base_tree}" "loki|loki-1.0.0|loki-1.0.0|1.0.0-xs.2|1" "tempo-distributed|||" 3> "${scratch}/conf")"
expect "rebuild rc" "0" "$?"
expect "rebuild version" "version: 1.0.0+xs.1" "$(git -C "${repo}" show "${rtree}:charts/loki/Chart.yaml" | grep '^version')"
expect "rebuild engine" "  engineTag: 1.0.0-xs.2" "$(git -C "${repo}" show "${rtree}:charts/loki/values.yaml" | grep engineTag)"
expect "rebuild test file" "image: ghcr.io/xscaler/loki:1.0.0-xs.2|version: \"1.0.0\"|version2: 1.0.0-xs.1|other: 11.0.0" "$(git -C "${repo}" show "${rtree}:charts/loki/tests/xs_image_test.yaml" | paste -sd'|')"
expect "rebuild changes only the xs files" "charts/loki/Chart.yaml charts/loki/tests/xs_image_test.yaml charts/loki/values.yaml" "$(git -C "${repo}" diff --name-only "${base_tree}" "${rtree}" | paste -sd' ')"
expect "rebuild keeps the chart patch" "# xs patched line" "$(git -C "${repo}" show "${rtree}:charts/loki/templates/_h.tpl" | sed -n 5p)"
# a second rebuild from +xs.1: the next number is the caller's (m+1)
GIT_INDEX_FILE="${scratch}/i6" git -C "${repo}" read-tree "${rtree}"
rtree2="$(cd "${repo}" && assemble_tree "${scratch}/idx6" "${u0}" "${u0}" "${rtree}" "loki|loki-1.0.0|loki-1.0.0|1.0.0-xs.5|2" "tempo-distributed|||" 3> "${scratch}/conf")"
expect "second rebuild" "version: 1.0.0+xs.2   engineTag: 1.0.0-xs.5" "$(git -C "${repo}" show "${rtree2}:charts/loki/Chart.yaml" | grep '^version') $(git -C "${repo}" show "${rtree2}:charts/loki/values.yaml" | grep engineTag)"
rgood="$(mk "${rtree}" -p "$(G rev-parse main)")"
XS_CHECK_ENGINE=false in_repo "${repo}" cmd_check charts "${rgood}"
expect "charts check accepts +xs.1" "0" "${RC}"
in_repo "${repo}" cmd_check identity "${rgood}"
expect "identity ok for a rebuild" "0" "${RC}"

# upstream-only refresh: both charts kept, the rest moves to upstream main
utree="$(cd "${repo}" && assemble_tree "${scratch}/idx7" "${u2}" "${u0}" "${base_tree}" "loki|||" "tempo-distributed|||" 3> "${scratch}/conf")"
expect "upstream-only keeps main's charts" "$(G rev-parse main:charts/loki main:charts/tempo-distributed | paste -sd' ') three" "$(G rev-parse "${utree}:charts/loki" "${utree}:charts/tempo-distributed" | paste -sd' ') $(git -C "${repo}" show "${utree}:README.md")"
# S1/S3: closed, merged and open PRs in the build (no API: the PR lookups are mocked)
export GITHUB_REPOSITORY=x/y
bargs=(--base-commit "$(G rev-parse main)" --base-tree "${base_tree}" --upstream-commit "${u2}" --upstream-base "${u0}" --bump "loki:loki-1.1.0:2.0.0-xs.0@${Z}")
pr_state() { echo "closed 7"; }
in_repo "${repo}" cmd_build "${bargs[@]}"
expect "closed PR is a skip" "0 yes yes" "${RC} $(grep -q 'skipped by closed PR #7' <<<"${OUT}" && echo yes || echo no) $(grep -q '^result=skipped' <<<"${OUT}" && echo yes || echo no)"
pr_state() { echo "merged 8"; }
in_repo "${repo}" cmd_build "${bargs[@]}"
expect "merged PR without the content fails" "1 yes" "${RC} $(grep -q 'has merged PR #8' <<<"${OUT}" && echo yes || echo no)"
pr_state() { echo "open 9"; }
REFSET="${scratch}/refset"
PRCOMMENTS="${scratch}/prcomments"
: > "${REFSET}"
: > "${PRCOMMENTS}"
P1="$(G rev-parse main)" MARKED=0 REFTIP=1111111111111111111111111111111111111111
gh() {
  case "$*" in
    *"git/ref/heads/"*) echo "${REFTIP}" ;;
    *".parents[0].sha"*) echo "${P1}" ;;
    *"pr view"*) echo "${MARKED}" ;;
    *"pr comment"*) echo "comment $2" >> "${PRCOMMENTS}" ;;
    *) echo "unexpected gh $*" >&2; return 1 ;;
  esac
}
api_commit() { echo 2222222222222222222222222222222222222222; }
api_ref_set() { echo "$1 $2" >> "${REFSET}"; }
# shellcheck disable=SC2034 # read by the code under test
branch_tip_is_bot() { BOT_TIP=1111111111111111111111111111111111111111; return 0; }
in_repo "${repo}" cmd_build "${bargs[@]}"
expect "open PR at main's head is left alone" "0 yes 0" "${RC} $(grep -q '^result=exists' <<<"${OUT}" && echo yes || echo no) $(wc -l < "${REFSET}")"
P1=3333333333333333333333333333333333333333
in_repo "${repo}" cmd_build "${bargs[@]}"
expect "stale bot PR is refreshed" "0 yes sync/loki-1.1.0 2222222222222222222222222222222222222222" "${RC} $(grep -q '^result=refreshed' <<<"${OUT}" && echo yes || echo no) $(cat "${REFSET}")"
# the branch moved between the check and the update: not refreshed, needs a manual update
: > "${REFSET}"
# shellcheck disable=SC2034 # read by the code under test
branch_tip_is_bot() { BOT_TIP=4444444444444444444444444444444444444444; return 0; }
: > "${PRCOMMENTS}"
in_repo "${repo}" cmd_build "${bargs[@]}"
expect "a branch that moved during the refresh is not overwritten" "0 yes 0 1" "${RC} $(grep -q '^result=needs-manual' <<<"${OUT}" && echo yes || echo no) $(wc -l < "${REFSET}") $(wc -l < "${PRCOMMENTS}")"
: > "${REFSET}"
branch_tip_is_bot() { return 1; }
: > "${PRCOMMENTS}"
in_repo "${repo}" cmd_build "${bargs[@]}"
expect "stale PR with human commits needs a manual update" "0 yes 0 1" "${RC} $(grep -q '^result=needs-manual' <<<"${OUT}" && echo yes || echo no) $(wc -l < "${REFSET}") $(wc -l < "${PRCOMMENTS}")"
MARKED=1
in_repo "${repo}" cmd_build "${bargs[@]}"
expect "the manual-update comment is not repeated" "1" "$(wc -l < "${PRCOMMENTS}")"
unset -f gh api_commit api_ref_set branch_tip_is_bot pr_state
# shellcheck source=/dev/null
source "${here}/xs-sync.sh"
set +e

# the bot's own tip: verified, author the App, committer GitHub, the title as built, parents main (+ upstream)
export GITHUB_REPOSITORY=x/y
TITLE="chore(sync): sync charts to loki-1.1.0"
BOTA="xscaler-gremlin[bot]" BOTE="351432774+xscaler-gremlin[bot]@users.noreply.github.com"
ROW=""
gh() {
  case "$*" in
    *"git/ref/heads/"*) echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
    *"git/commits/"*) printf '%b\n' "${ROW}" ;;
  esac
}
tip_ok() { (cd "${repo}" && branch_tip_is_bot sync/loki-1.1.0 "${TITLE}") && echo yes || echo no; }
ROW="2\t${u2}\t${TITLE}\t${BOTA}\t${BOTE}\tGitHub\tnoreply@github.com\ttrue"
expect "bot tip, two parents" yes "$(tip_ok)"
ROW="1\t\t${TITLE}\t${BOTA}\t${BOTE}\tGitHub\tnoreply@github.com\ttrue"
expect "bot tip, one parent" yes "$(tip_ok)"
ROW="2\t$(G rev-parse refs/heads/down)\t${TITLE}\t${BOTA}\t${BOTE}\tGitHub\tnoreply@github.com\ttrue"
expect "second parent not on upstream main" no "$(tip_ok)"
ROW="3\t${u2}\t${TITLE}\t${BOTA}\t${BOTE}\tGitHub\tnoreply@github.com\ttrue"
expect "three parents" no "$(tip_ok)"
ROW="1\t\t${TITLE}\tA Human\ta@example.com\tGitHub\tnoreply@github.com\ttrue"
expect "human author" no "$(tip_ok)"
ROW="1\t\t${TITLE}\t${BOTA}\t${BOTE}\tA Human\ta@example.com\ttrue"
expect "human committer" no "$(tip_ok)"
ROW="1\t\t${TITLE}\t${BOTA}\t${BOTE}\tGitHub\tnoreply@github.com\tfalse"
expect "unverified" no "$(tip_ok)"
ROW="1\t\tother title\t${BOTA}\t${BOTE}\tGitHub\tnoreply@github.com\ttrue"
expect "other title" no "$(tip_ok)"
ROW="1\t\t${TITLE}\t\t\tGitHub\tnoreply@github.com\ttrue"
expect "no author" no "$(tip_ok)"
unset -f gh
# the ref is read again right before it is moved
api_ref_set() { echo "$1 $2" > "${scratch}/moved"; }
gh() { echo bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; }
: > "${scratch}/moved"
api_ref_set_if sync/loki-1.1.0 cafe aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa && r=moved || r=kept
expect "api_ref_set_if refuses a moved tip" "kept 0" "${r} $(wc -c < "${scratch}/moved")"
api_ref_set_if sync/loki-1.1.0 cafe bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb && r=moved || r=kept
expect "api_ref_set_if moves an unchanged tip" "moved sync/loki-1.1.0 cafe" "${r} $(cat "${scratch}/moved")"
unset -f gh api_ref_set

# S3: the first parent of a sync commit is main's current head
in_repo "${repo}" cmd_check parents "$(mk "${tree}" -p "${u0}" -p "${u2}")"
expect "parents: an older main head is stale" "1 yes" "${RC} $(grep -q 'is not the current main head' <<<"${OUT}" && echo yes || echo no)"

# S4: upstream .github changes and the workflows to disable
expect "github changes" "modified .github/workflows/ci.yaml" "$(cd "${repo}" && xs_github_changes "${u0}" "${u2}")"
expect "github changes skip the xs files" "" "$(cd "${repo}" && xs_github_changes "${u0}" main)"
printf '1\t.github/workflows/xs-test.yml\tactive\n2\t.github/workflows/ci.yaml\tactive\n3\t.github/workflows/old.yml\tdisabled_manually\n4\tdynamic/x\tactive\n5\t.github/workflows/xs-evil.yml.txt\tactive\n6\t.github/workflows/xs-a/b.yml\tactive\n' > "${scratch}/wf"
expect "workflows to disable" "$(printf '2\t.github/workflows/ci.yaml\n5\t.github/workflows/xs-evil.yml.txt\n6\t.github/workflows/xs-a/b.yml')" "$(xs_workflows_to_disable < "${scratch}/wf")"
DISABLED="${scratch}/disabled"
: > "${DISABLED}"
gh() {
  case "$*" in
    *"--paginate"*) cat "${scratch}/wf" ;;
    *"--method PUT"*) echo "$4" >> "${DISABLED}" ;;
  esac
}
in_repo "${repo}" cmd_disable_workflows
expect "disable-upstream-workflows disables only those" "0 repos/x/y/actions/workflows/2/disable repos/x/y/actions/workflows/5/disable repos/x/y/actions/workflows/6/disable" "${RC} $(paste -sd' ' "${DISABLED}")"
unset -f gh

# S5: upstream text in PR bodies
# shellcheck disable=SC2016 # backticks are the input
expect "neutralize" "$(printf "@\xe2\x80\x8buser \xe2\x80\xb9b\xe2\x80\xba 'x' 'y")" "$(printf '%s' '@user <b> `x` ```y' | xs_neutralize)"
expect "pr state open wins" "open 3" "$(echo '[{"number":2,"state":"MERGED","isCrossRepository":false},{"number":3,"state":"OPEN","isCrossRepository":false}]' | xs_pr_state)"
expect "pr state merged" "merged 2" "$(echo '[{"number":2,"state":"MERGED","isCrossRepository":false},{"number":4,"state":"CLOSED","isCrossRepository":false}]' | xs_pr_state)"
expect "pr state closed" "closed 4" "$(echo '[{"number":4,"state":"CLOSED","isCrossRepository":false}]' | xs_pr_state)"
expect "pr state fork ignored" "none" "$(echo '[{"number":5,"state":"OPEN","isCrossRepository":true}]' | xs_pr_state)"
expect "pr state none" "none" "$(echo '[]' | xs_pr_state)"

# a patch that conflicts with the new chart tag: no tree, the file is reported
G checkout -q -b conflicting main
sed -i '30s/.*/# our rewrite of the line upstream edits/' "${repo}/charts/loki/templates/_h.tpl"
G commit -q -am conflicting
ctree="$(G rev-parse 'conflicting^{tree}')"
in_repo "${repo}" bash -c 'true'
(cd "${repo}" && assemble_tree "${scratch}/idx4" "${u2}" "${u0}" "${ctree}" "${specs[@]}" 3> "${scratch}/conf" > /dev/null 2>&1)
expect "conflict rc and file" "1 charts/loki/templates/_h.tpl" "$? $(cat "${scratch}/conf")"
G checkout -q main

# the PR checks, on a commit that holds the built tree
good="$(mk "${tree}" -p "$(G rev-parse main)" -p "${u2}")"
in_repo "${repo}" cmd_check identity "${good}"
expect "identity ok" "0" "${RC}"
in_repo "${repo}" cmd_check parents "${good}"
expect "parents ok" "0" "${RC}"
XS_CHECK_ENGINE=false in_repo "${repo}" cmd_check charts "${good}"
expect "charts ok" "0" "${RC}"

# check charts with the engine verification on: the tag must still resolve to the digest
# the sync recorded, and the digest must be signed and attested
D1="sha256:$(printf 'a%.0s' {1..64})"
D2="sha256:$(printf 'b%.0s' {1..64})"
CR="${D1}" CS=0 GA=0
crane() { [[ "$1" == digest ]] && echo "${CR}"; }
cosign() { if ((CS == 0)); then return 0; fi; echo "Error: no signatures found" >&2; return 1; }
gh() { if ((GA == 0)); then return 0; fi; echo "Error: no attestations found" >&2; return 1; }
body="${scratch}/body.md"
printf 'text\n<!-- xs-sync:engine loki %s -->\n<!-- xs-sync:engine tempo-distributed %s -->\n' "${D1}" "${D1}" > "${body}"
in_repo "${repo}" cmd_check charts "${good}" "${body}"
expect "digest check passes" "0" "${RC}"
CR="${D2}"
in_repo "${repo}" cmd_check charts "${good}" "${body}"
expect "a retagged engine is refused" "1 yes" "${RC} $(grep -q "resolves to ${D2}, the sync verified ${D1}" <<<"${OUT}" && echo yes || echo no)"
CR="${D1}"
printf 'text\n' > "${body}"
in_repo "${repo}" cmd_check charts "${good}" "${body}"
expect "a changed engine needs a recorded digest" "1 yes" "${RC} $(grep -q 'records no verified digest for 2.0.0-xs.0' <<<"${OUT}" && echo yes || echo no)"
printf 'text\n<!-- xs-sync:engine loki %s -->\n' "${D1}" > "${body}"
CS=1
in_repo "${repo}" cmd_check charts "${good}" "${body}"
expect "an unsigned digest is refused" "1 yes" "${RC} $(grep -q 'is not signed and attested' <<<"${OUT}" && echo yes || echo no)"
CS=0 GA=1
in_repo "${repo}" cmd_check charts "${good}" "${body}"
expect "an unattested digest is refused" "1 yes" "${RC} $(grep -q 'is not signed and attested' <<<"${OUT}" && echo yes || echo no)"
unset -f crane cosign gh

# single parent: the upstream base is the merge base with upstream main
one="$(mk "${tree2}" -p "$(G rev-parse main)")"
in_repo "${repo}" cmd_check identity "${one}"
expect "identity ok, one parent" "0" "${RC}"
# a README that differs from upstream main
bad_idx="${scratch}/badidx"
GIT_INDEX_FILE="${bad_idx}" git -C "${repo}" read-tree "${tree}"
GIT_INDEX_FILE="${bad_idx}" git -C "${repo}" update-index --add --cacheinfo "100644,$(echo edited | git -C "${repo}" hash-object -w --stdin),README.md"
badtree="$(GIT_INDEX_FILE="${bad_idx}" git -C "${repo}" write-tree)"
bad="$(mk "${badtree}" -p "$(G rev-parse main)" -p "${u2}")"
in_repo "${repo}" cmd_check identity "${bad}"
expect "identity fails on README" "1 yes" "${RC} $(grep -q 'README.md differs' <<<"${OUT}" && echo yes || echo no)"
# a chart file that differs from the chart tag and is not a patch path
GIT_INDEX_FILE="${bad_idx}" git -C "${repo}" read-tree "${tree}"
GIT_INDEX_FILE="${bad_idx}" git -C "${repo}" update-index --add --cacheinfo "100644,$(echo edited | git -C "${repo}" hash-object -w --stdin),charts/loki/templates/new.tpl"
badtree="$(GIT_INDEX_FILE="${bad_idx}" git -C "${repo}" write-tree)"
bad="$(mk "${badtree}" -p "$(G rev-parse main)" -p "${u2}")"
in_repo "${repo}" cmd_check identity "${bad}"
expect "identity fails on a chart file" "1 yes" "${RC} $(grep -q 'new.tpl differs from loki-1.1.0' <<<"${OUT}" && echo yes || echo no)"
# a second parent that is not upstream main, and a first parent that is not main
G checkout -q -b stray main
echo s > "${repo}/stray" && G add stray && G commit -q -m stray
stray="$(G rev-parse HEAD)"
G checkout -q main
in_repo "${repo}" cmd_check parents "$(mk "${tree}" -p "$(G rev-parse main)" -p "${stray}")"
expect "parents: second parent not on upstream main" "1" "${RC}"
in_repo "${repo}" cmd_check parents "$(mk "${tree}" -p "${stray}" -p "${u2}")"
expect "parents: first parent not on main" "1" "${RC}"
# wrong chart version in Chart.yaml
GIT_INDEX_FILE="${bad_idx}" git -C "${repo}" read-tree "${tree}"
GIT_INDEX_FILE="${bad_idx}" git -C "${repo}" update-index --cacheinfo "100644,$(git -C "${repo}" show "${tree}:charts/loki/Chart.yaml" | sed 's/^version: 1.1.0/version: 1.2.0/' | git -C "${repo}" hash-object -w --stdin),charts/loki/Chart.yaml"
badtree="$(GIT_INDEX_FILE="${bad_idx}" git -C "${repo}" write-tree)"
XS_CHECK_ENGINE=false in_repo "${repo}" cmd_check charts "$(mk "${badtree}" -p "$(G rev-parse main)" -p "${u2}")"
expect "charts: version must belong to the chart tag" "1" "${RC}"

# a squash merge of the sync drops the upstream parent: detect refuses to continue
G checkout -q -b squashed main
G read-tree "${tree}" && G checkout-index -a -f && G add -A && G commit -q -m squash
G update-ref refs/remotes/origin/main squashed
XS_ENGINE_MOCK="loki:2.0.0:0"
in_repo "${repo}" cmd_detect --base origin/main
expect "squash is detected" "1 yes" "${RC} $(grep -q 'merge commit' <<<"${OUT}" && echo yes || echo no)"
G checkout -q main
G update-ref refs/remotes/origin/main main
unset XS_MOCK_OK XS_ENGINE_MOCK

# api_plan: modify, delete, rename, mode change, symlink, binary.
repo="${scratch}/plan"
git init -q -b main "${repo}"
printf 'a\nb\nc\nd\ne\nf\n' > "${repo}/mod.txt"
printf 'x\ny\nz\n1\n2\n3\n' > "${repo}/ren.txt"
echo gone > "${repo}/del.txt"
echo '#!/bin/sh' > "${repo}/mode.sh"
G add . && G commit -q -m base
printf 'a\nB\nc\nd\ne\nf\n' > "${repo}/mod.txt"
G mv ren.txt ren2.txt
G rm -q del.txt
chmod +x "${repo}/mode.sh"
ln -s mod.txt "${repo}/ln"
printf '\000\001\002\377' > "${repo}/bin.dat"
G add -A && G commit -q -m head
in_repo "${repo}" api_plan "HEAD~1^{tree}" "HEAD^{tree}"
q() { jq -r "select(.path == \"$1\") | $2" <<<"${OUT}"; }
expect "plan rc" "0" "${RC}"
expect "plan modify" "100644 true" "$(q mod.txt '"\(.mode) \(.blob)"')"
expect "plan delete" "null" "$(q del.txt '.sha')"
expect "plan rename old" "null" "$(q ren.txt '.sha')"
expect "plan rename new" "100644 true" "$(q ren2.txt '"\(.mode) \(.blob)"')"
expect "plan mode only" "100755 false" "$(q mode.sh '"\(.mode) \(.blob)"')"
expect "plan symlink" "120000 true" "$(q ln '"\(.mode) \(.blob)"')"
expect "plan binary" "100644 true" "$(q bin.dat '"\(.mode) \(.blob)"')"
expect "plan entries" "7" "$(jq -s length <<<"${OUT}")"
# type change: file to symlink
G checkout -q -b typechg HEAD
rm "${repo}/mod.txt" && ln -s ln "${repo}/mod.txt" && G add -A && G commit -q -m typechg
in_repo "${repo}" api_plan "HEAD~1^{tree}" "HEAD^{tree}"
expect "plan type change" "120000 true" "$(q mod.txt '"\(.mode) \(.blob)"')"

# file to directory, directory to file, submodule
G checkout -q -b f2d main
rm "${repo}/del.txt" 2> /dev/null; echo f > "${repo}/swap" && G add -A && G commit -q -m swapfile
rm "${repo}/swap" && mkdir "${repo}/swap" && echo f > "${repo}/swap/inner" && G add -A && G commit -q -m swapdir
in_repo "${repo}" api_plan "HEAD~1^{tree}" "HEAD^{tree}"
expect "file to dir fails" "1 yes" "${RC} $(grep -q 'file to directory' <<<"${OUT}" && echo yes || echo no)"
in_repo "${repo}" api_plan "HEAD^{tree}" "HEAD~1^{tree}"
expect "dir to file fails" "1 yes" "${RC} $(grep -q 'directory to file' <<<"${OUT}" && echo yes || echo no)"
G checkout -q -b sub main
G update-index --add --cacheinfo "160000,$(G rev-parse HEAD),vendored" && G commit -q -m submodule
in_repo "${repo}" api_plan "HEAD~1^{tree}" "HEAD^{tree}"
expect "submodule fails" "1 yes" "${RC} $(grep -q 'submodule' <<<"${OUT}" && echo yes || echo no)"

# ---------------------------------------------------------------------------
# helm-charts: the namespace in build and identity, closed upstream refreshes
# ---------------------------------------------------------------------------
repo="${scratch}/h"
G checkout -q -b evilup "${u2}"
mkdir -p "${repo}/.github/actions/xs-evil"
echo x > "${repo}/.github/actions/xs-evil/action.yml"
G add -A && G commit -q -m evil
evil="$(G rev-parse HEAD)"
G checkout -q main
pr_state() { echo none; }
in_repo "${repo}" cmd_build "${bargs[@]/${u2}/${evil}}"
expect "build rejects an upstream commit with xs paths" "1 yes" "${RC} $(grep -q 'holds paths in the xs namespace' <<<"${OUT}" && grep -q '.github/actions/xs-evil/action.yml' <<<"${OUT}" && echo yes || echo no)"
unset -f pr_state
G update-ref refs/remotes/origin/main main
G update-ref refs/remotes/origin/upstream/main "${u2}"
in_repo "${repo}" cmd_check identity "$(mk "${tree}" -p "${u0}" -p "${evil}")"
expect "identity rejects upstream xs paths" "1 yes" "${RC} $(grep -q 'contains .github/actions/xs-evil/action.yml' <<<"${OUT}" && echo yes || echo no)"

# closed upstream refresh PRs are skipped for the upstream tip they carry
mrk() { printf '<!-- xs-sync:upstream %s -->' "$1"; }
pr() { # <number> <state> <head> <author> <cross> <body>
  jq -cn --argjson n "$1" --arg s "$2" --arg h "$3" --arg a "$4" --argjson c "$5" --arg b "$6" \
    '{number:$n,state:$s,headRefName:$h,isCrossRepository:$c,author:{login:$a},body:$b}'
}
TIP="${u2}"
OLD=1111111111111111111111111111111111111111
jlist() { jq -s . ; }
expect "closed pr: marker matches" "7" "$(pr 7 CLOSED sync/upstream-20261101 app/xscaler-gremlin false "$(printf 'x\n%s\n' "$(mrk "${TIP}")")" | jlist | xs_closed_upstream_pr "${TIP}")"
expect "closed pr: the newest one wins" "9" "$({ pr 7 CLOSED sync/upstream-20261101 app/xscaler-gremlin false "$(mrk "${TIP}")"; pr 9 CLOSED sync/upstream-20261102 app/xscaler-gremlin false "$(mrk "${TIP}")"; } | jlist | xs_closed_upstream_pr "${TIP}")"
expect "closed pr: other tip" "" "$(pr 7 CLOSED sync/upstream-20261101 app/xscaler-gremlin false "$(mrk "${OLD}")" | jlist | xs_closed_upstream_pr "${TIP}")"
expect "closed pr: merged is not a skip" "" "$(pr 7 MERGED sync/upstream-20261101 app/xscaler-gremlin false "$(mrk "${TIP}")" | jlist | xs_closed_upstream_pr "${TIP}")"
expect "closed pr: open is not a skip" "" "$(pr 7 OPEN sync/upstream-20261101 app/xscaler-gremlin false "$(mrk "${TIP}")" | jlist | xs_closed_upstream_pr "${TIP}")"
expect "closed pr: not the bot" "" "$(pr 7 CLOSED sync/upstream-20261101 someone false "$(mrk "${TIP}")" | jlist | xs_closed_upstream_pr "${TIP}")"
expect "closed pr: from a fork" "" "$(pr 7 CLOSED sync/upstream-20261101 app/xscaler-gremlin true "$(mrk "${TIP}")" | jlist | xs_closed_upstream_pr "${TIP}")"
expect "closed pr: not an upstream head" "" "$(pr 7 CLOSED sync/loki-1.1.0 app/xscaler-gremlin false "$(mrk "${TIP}")" | jlist | xs_closed_upstream_pr "${TIP}")"
expect "closed pr: marker inside a line is not a marker" "" "$(pr 7 CLOSED sync/upstream-20261101 app/xscaler-gremlin false "see $(mrk "${TIP}") here" | jlist | xs_closed_upstream_pr "${TIP}")"
expect "closed pr: empty list" "" "$(echo '[]' | xs_closed_upstream_pr "${TIP}")"
# the build: tomorrow's sync/upstream-<date> branch is skipped while the closed PR carries the tip
uargs=(--base-commit "$(G rev-parse main)" --base-tree "${base_tree}" --upstream-commit "${u2}" --upstream-base "${u0}" --upstream-only)
pr_state() { echo none; }
closed_upstream_pr() { echo 12; }
XS_TODAY=20261103 in_repo "${repo}" cmd_build "${uargs[@]}"
expect "build: skipped by a closed PR of the same upstream tip" "0 yes yes" "${RC} $(grep -q 'skipped by closed PR #12' <<<"${OUT}" && echo yes || echo no) $(grep -q '^result=skipped' <<<"${OUT}" && echo yes || echo no)"
# no closed PR for the tip: the refresh PR is opened and records the tip
closed_upstream_pr() { echo; }
api_commit() { echo 2222222222222222222222222222222222222222; }
api_ref_set() { :; }
branch_guard() { :; }
gh() {
  case "$*" in
    *"git/commits/"*) echo true ;;
    *"issue list"*) echo ;;
    *"pr create"*)
      while (($#)); do
        if [[ "$1" == --body-file ]]; then cp "$2" "${scratch}/prbody"; fi
        shift
      done
      echo https://github.com/x/y/pull/1
      ;;
    *) echo "unexpected gh $*" >&2; return 1 ;;
  esac
}
XS_TODAY=20261103 in_repo "${repo}" cmd_build "${uargs[@]}"
expect "build: a refresh PR records the upstream tip" "0 yes" "${RC} $(grep -qxF "<!-- xs-sync:upstream ${u2} -->" "${scratch}/prbody" && echo yes || echo no)"
unset -f gh api_commit api_ref_set branch_guard pr_state closed_upstream_pr
# shellcheck source=/dev/null
source "${here}/xs-sync.sh"
set +e
# the gh call: closed PRs, newest first, only the fields the filter reads
gh() { printf '%s\n' "$*" > "${scratch}/ghcall"; echo '[]'; }
closed_upstream_pr "${u2}" > /dev/null
expect "closed_upstream_pr asks for closed PRs" "yes" "$(grep -q -e 'pr list --state closed' "${scratch}/ghcall" && echo yes)"
in_repo "${repo}" closed_upstream_pr "not-a-sha"
expect "closed_upstream_pr validates the sha" "1" "${RC}"
unset -f gh

# ---------------------------------------------------------------------------
# xs namespace: upstream never owns it, a sync result never changes it
# ---------------------------------------------------------------------------
ns_yes() { if xs_ns_path "$1"; then echo yes; else echo no; fi; }
expect "ns workflow" "yes" "$(ns_yes .github/workflows/xs-evil.yml)"
expect "ns script" "yes" "$(ns_yes .github/scripts/xs-x.sh)"
expect "ns nested" "yes" "$(ns_yes .github/scripts/xs-x/y.sh)"
expect "ns upstream workflow" "no" "$(ns_yes .github/workflows/ci.yml)"
expect "ns lookalike" "no" "$(ns_yes .github/workflows/not-xs-x.yml)"
expect "ns outside .github" "no" "$(ns_yes docs/xs-x.md)"
expect "ns action" "yes" "$(ns_yes .github/actions/xs-evil/action.yml)"
expect "ns chart path is not namespace" "no" "$(ns_yes charts/loki/values.yaml)"

repo="${scratch}/ns"
git init -q -b main "${repo}"
printf 'one\ntwo\nthree\n' > "${repo}/a.txt"
mkdir -p "${repo}/.github/workflows"
echo ci > "${repo}/.github/workflows/ci.yml"
G add -A && G commit -q -m base && G tag v1.0.0
base_tag_commit="$(G rev-parse HEAD)"
echo ours > "${repo}/.github/workflows/xs-x.yml"
G add -A && G commit -q -m patch
main_tree="$(G rev-parse 'HEAD^{tree}')"
G update-ref refs/heads/mainline HEAD
# v1.0.1: upstream adds an xs-* workflow of its own
G checkout -q -b u1 "${base_tag_commit}"
echo evil > "${repo}/.github/workflows/xs-evil.yml"
printf 'one\ntwo\nthree\nfour\n' > "${repo}/a.txt"
G add -A && G commit -q -m u1 && G tag v1.0.1
# v1.0.2: upstream rewrites one of our files (path matches xs-*)
G checkout -q -b u2 "${base_tag_commit}"
echo theirs > "${repo}/.github/workflows/xs-x.yml"
G add -A && G commit -q -m u2 && G tag v1.0.2
# v1.0.3: a clean upstream release
G checkout -q -b u3 "${base_tag_commit}"
printf 'one\ntwo\nthree\nfive\n' > "${repo}/a.txt"
G add -A && G commit -q -m u3 && G tag v1.0.3
# result = v1.0.3 plus our patch
result_tree() { # <tag> <xs-x content>
  G checkout -q --detach "$1"
  echo "$2" > "${repo}/.github/workflows/xs-x.yml"
  G add -A && G commit -q -m result
  G rev-parse 'HEAD^{tree}'
}
in_repo "${repo}" xs_ns_violations v1.0.3 "${main_tree}" "$(result_tree v1.0.3 ours)"
expect "ns clean sync" "0 " "${RC} ${OUT}"
in_repo "${repo}" xs_ns_violations v1.0.1
expect "ns upstream adds xs file" "0 upstream v1.0.1 contains .github/workflows/xs-evil.yml" "${RC} ${OUT}"
in_repo "${repo}" xs_ns_violations v1.0.2
expect "ns upstream owns one of ours" "0 upstream v1.0.2 contains .github/workflows/xs-x.yml" "${RC} ${OUT}"
in_repo "${repo}" xs_ns_violations v1.0.3 "${main_tree}" "$(result_tree v1.0.3 changed)"
expect "ns result differs from main" "0 result differs from main at .github/workflows/xs-x.yml" "${RC} ${OUT}"
in_repo "${repo}" xs_ns_violations no-such-ref
expect "ns git failure is an error" "1" "${RC}"
# a path with a newline cannot forge a log line
G checkout -q --detach v1.0.3
printf 'x\n' > "${repo}/.github/workflows/xs-$(printf 'a\nb').yml"
G add -A && G commit -q -m nl && G tag v1.0.4
in_repo "${repo}" xs_ns_violations v1.0.4
expect "ns path is sanitised" "1" "$(grep -c '' <<<"${OUT}")"
G checkout -q main

# workflows to disable: an xs-* workflow upstream also has is not ours
wfl="$(printf '1\t.github/workflows/xs-x.yml\tactive\n2\t.github/workflows/xs-evil.yml\tactive\n3\t.github/workflows/ci.yml\tactive\n')"
wf_with() { (cd "${repo}" && XS_UPSTREAM_REFS="$1" xs_workflows_to_disable <<<"${wfl}" | cut -f1 | tr '\n' ' '); }
expect "disable: no upstream refs" "3 " "$(wf_with '')"
expect "disable: upstream tag with xs file" "2 3 " "$(wf_with 'v1.0.1')"
expect "disable: clean upstream tag" "3 " "$(wf_with 'v1.0.3')"
expect "disable: upstream owns one of ours" "1 3 " "$(wf_with 'v1.0.2')"
expect "disable: any ref counts" "2 3 " "$(wf_with 'v1.0.3 v1.0.1')"

# mirror: upstream main (or a new tag) with xs paths is mirrored, but fails the run
mirror_check() { # <upstream main branch dir content tag> -> rc
  local mrepo="${scratch}/mirror-$1"
  git init -q --bare -b main "${mrepo}"
  git -C "${mrepo}" fetch -q "${repo}" "refs/tags/$1:refs/heads/main"
  local clone="${scratch}/mirror-clone-$1"
  git init -q -b work "${clone}"
  git -C "${clone}" remote add "${XS_UPSTREAM_REMOTE}" "${mrepo}"
  (cd "${clone}" && XS_RETRY_SLEEP=0 mirror_ns_check "${@:2}") 2>&1
  echo "rc=$?"
}
out="$(mirror_check v1.0.1)"
expect "mirror check: upstream main with xs path" "yes 1" "$(grep -q 'xs-evil.yml' <<<"${out}" && echo yes) $(grep -c '^rc=1' <<<"${out}")"
out="$(mirror_check v1.0.3)"
expect "mirror check: clean upstream main" "rc=0" "$(grep '^rc=' <<<"${out}")"
# a new tag with xs paths fails too
clone="${scratch}/mirror-clone-v1.0.3"
git -C "${clone}" fetch -q --no-tags "${scratch}/ns" refs/tags/v1.0.1:refs/tags/v1.0.1
out="$(cd "${clone}" && XS_RETRY_SLEEP=0 mirror_ns_check refs/tags/v1.0.1 2>&1; echo "rc=$?")"
expect "mirror check: new tag with xs path" "yes 1" "$(grep -q 'tags/v1.0.1' <<<"${out}" && echo yes) $(grep -c '^rc=1' <<<"${out}")"

# issue lookups only trust issues of the bot, with our label
calls="${scratch}/gh-calls"
gh() { printf '%s\n' "$*" >> "${calls}"; }
: > "${calls}"
issue_find "sync: v1.0.1 conflicts" sync-conflict > /dev/null
expect "issue_find author and label" "yes yes" "$(grep -q -e '--author app/xscaler-gremlin' "${calls}" && echo yes) $(grep -q -e '--label sync-conflict' "${calls}" && echo yes)"
: > "${calls}"
issue_find "sync: failed" sync-failed "${XS_ISSUE_AUTHOR_ACTIONS}" > /dev/null
expect "issue_find failure issue author" "yes" "$(grep -q -e '--author app/github-actions' "${calls}" && echo yes)"
in_repo "${repo}" issue_find "sync: x" ""
expect "issue_find needs a label" "1" "${RC}"
: > "${calls}"
cmd_issue_failed https://github.com/xscaler/loki/actions/runs/1 > /dev/null 2>&1
expect "issue-failed looks up with the Actions author" "yes yes" "$(grep -q -e '--author app/github-actions' "${calls}" && echo yes) $(grep -q -e '--label sync-failed' "${calls}" && echo yes)"
: > "${calls}"
rehearsal_cleanup > /dev/null 2>&1
REHEARSAL_TITLE="rehearsal sync: x" rehearsal_cleanup > /dev/null 2>&1
expect "rehearsal cleanup looks up by author and label" "yes yes" "$(grep -q -e '--author app/xscaler-gremlin' "${calls}" && echo yes) $(grep -q -e '--label rehearsal' "${calls}" && echo yes)"
unset -f gh

echo "pass=${pass} fail=${fail}"
[[ "${fail}" -eq 0 ]]
