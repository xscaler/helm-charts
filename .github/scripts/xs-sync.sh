#!/usr/bin/env bash
# shellcheck disable=SC2310,SC2249 # helpers run in if/|| on purpose and case statements without a default are intended
# xScaler fork: upstream sync logic, shared by xs-sync.yml and xs-sync-check.yml.
#
# helm-charts has no repo-wide release tags. The fork's main is "an upstream
# main commit, plus charts/loki and charts/tempo-distributed pinned to one
# upstream chart tag each, plus our patch set". This script mirrors upstream
# main and tags, and opens a PR from sync/<chart>-<ver>[_<chart>-<ver>] into
# main when one of our charts has a newer stable chart tag whose engine image
# (ghcr.io/xscaler/<engine>:<appVersion>-xs.N) is released and cosign verified.
# A chart whose newest chart tag has no released engine yet, but whose current
# appVersion has a newer verified engine build than the chart's engineTag, is rebuilt:
# same chart tag, version <ver>+xs.<m+1>, engineTag <appVersion>-xs.<N>. The sync head
# is then sync/<tag>-xs.<m+1>.
# The PR commit has tree = upstream main with each chart subtree replaced by the
# chart tag's tree plus our chart patch; parents = main and the upstream main
# commit used (only one parent when upstream main has nothing new).
#
# Porting to another fork: copy this file and change only the parameter block
# below. Every parameter can be overridden from the environment, which the unit
# tests use.
#
# Subcommands:
#   mirror [--dry-run]            push upstream main and tags to origin
#   pick <chart> <current-tag> [--cap TAG]
#                                 pick the chart target from tags on stdin
#   ghcr-login                    log in to the engine registry with GH_TOKEN
#   disable-upstream-workflows    disable every active workflow that is not ours
#   engines [--base REF]          per chart: the verified engine release for main's appVersion
#   detect [--base REF] [--upstream REF] [--open-heads FILE] [--cap TAG]...
#                                 per chart: current tag, newest released target
#   build --base-commit SHA --base-tree SHA --upstream-commit SHA
#         --upstream-base SHA --bump chart:tag:engine... [--branch B] [--no-pr]
#         [--issue-title T --issue-label L]
#                                 rebuild the tree from upstream main and chart tags
#   supersede <head-suffix> <sync/head>...  close stale sync PRs and issues
#   open-heads <out-file>         write head branches of our own open PRs
#   rehearse clean|upstream|merge|conflict|nothing|rebuild
#                                 run detect+build against an artificial base
#   check identity|parents|charts [HEAD [PR-BODY-FILE]]  PR checks for a sync/* head
#   flagdiff <old-dir> <new-dir> <out.md>         binary flag set diff (unused here)
#   flagreport <old-bin> <new-bin> <out.md>       the same for built binaries
#   body-fill <body-file> <fill-file>             fill the flag diff placeholder
#   issue-failed <run-url>        open or update the "sync: failed" issue
#
# Credentials: GH_TOKEN (GitHub App token, jobs that write), GITHUB_REPOSITORY.
# The build and rehearse commands never run `git push`: they write through the
# git data API, so the merge commit is signed by GitHub (Verified) and the
# job holds no persisted git credentials.

# The sed programs below wrap text in markdown backticks on purpose.
# shellcheck disable=SC2016
set -euo pipefail
shopt -s inherit_errexit

# ---------------------------------------------------------------------------
# Parameter block: the only part that changes between repos.
# ---------------------------------------------------------------------------
# Upstream repository (owner/name) and the URL git fetches from.
XS_UPSTREAM_REPO="${XS_UPSTREAM_REPO:-grafana-community/helm-charts}"
XS_UPSTREAM_URL="${XS_UPSTREAM_URL:-https://github.com/${XS_UPSTREAM_REPO}.git}"
# Stable release tags: ERE with exactly three groups (major, minor, patch).
# The default is only a placeholder here: chart tags are <chart>-X.Y.Z and the
# chart code sets these two per chart (with_chart).
XS_TAG_REGEX="${XS_TAG_REGEX:-^v([0-9]+)\\.([0-9]+)\\.([0-9]+)\$}"
XS_TAG_FORMAT="${XS_TAG_FORMAT:-v%s}"
# Upstream branches to mirror as origin/upstream/<name>. There is no release
# branch naming here: only main is tracked.
XS_BRANCH_REGEX="${XS_BRANCH_REGEX:-^main\$}"
# Paths outside the charts that may differ from upstream main (our patch set),
# as shell globs matched against the full path ("*" also matches "/").
XS_PATCH_PATHS=(
  ".github/workflows/xs-*"
  ".github/scripts/xs-*"
  ".github/actions/xs-*"
)
# The namespace upstream must never own: paths that only this fork may carry.
# Shell globs like XS_PATCH_PATHS, but workflows, scripts and actions only (not
# chart paths). A path here must be identical in main and in a sync result, and
# absent from every upstream tree.
XS_NS_PATHS=(
  ".github/workflows/xs-*"
  ".github/scripts/xs-*"
  ".github/actions/xs-*"
)
# Our charts: chart directory under charts/ and the engine image it deploys.
XS_CHARTS=(loki tempo-distributed)
declare -A XS_CHART_ENGINE=([loki]=loki [tempo-distributed]=tempo)
# Engine release identity: the workflow that signs engine images.
XS_ENGINE_ORG="${XS_ENGINE_ORG:-xscaler}"
XS_ENGINE_REGISTRY="${XS_ENGINE_REGISTRY:-ghcr.io}"
XS_ENGINE_ISSUER="${XS_ENGINE_ISSUER:-https://token.actions.githubusercontent.com}"
# Files in a chart whose content carries the chart version or the engine tag and
# is rewritten on a bump: Chart.yaml (version), values.yaml (xscaler.engineTag)
# and the listed test files (every occurrence of the old appVersion).
XS_ENGINE_TAG_FILE="values.yaml"
XS_VERSION_TEST_FILES=("tests/xs_image_test.yaml")
# The author of the commits the bot makes through the git data API (GitHub signs them and
# is the committer).
XS_BOT_LOGIN="${XS_BOT_LOGIN:-xscaler-gremlin[bot]}"
XS_BOT_EMAIL="${XS_BOT_EMAIL:-351432774+xscaler-gremlin[bot]@users.noreply.github.com}"
# Upstream drift: open an upstream-only refresh PR when main is further behind upstream
# main than this, even with no chart to move.
XS_DRIFT_COMMITS="${XS_DRIFT_COMMITS:-200}"
XS_DRIFT_DAYS="${XS_DRIFT_DAYS:-30}"
# Binary for the flag diff. Empty XS_BINARY_PKG skips it (charts, libraries).
XS_BINARY_PKG="${XS_BINARY_PKG-}"
XS_BINARY_NAME="${XS_BINARY_NAME:-}"
XS_HELP_FLAGS="${XS_HELP_FLAGS:--help}"
# ---------------------------------------------------------------------------

# Who opens the issues the bot looks up by title. gh --author slugs: the App for
# sync issues, the Actions bot for the failure issue (its job holds GITHUB_TOKEN).
# Outsiders can open issues on a public repo; a title match alone is not trusted.
XS_ISSUE_AUTHOR="${XS_ISSUE_AUTHOR:-app/xscaler-gremlin}"
XS_ISSUE_AUTHOR_ACTIONS="${XS_ISSUE_AUTHOR_ACTIONS:-app/github-actions}"

XS_MAIN_BRANCH="${XS_MAIN_BRANCH:-main}"
XS_UPSTREAM_REMOTE="xs-upstream"
XS_FLAG_BEGIN="<!-- xs-sync:flag-diff:begin -->"
XS_FLAG_END="<!-- xs-sync:flag-diff:end -->"

log() { echo "$*" >&2; }
die() {
  echo "::error::$*" >&2
  exit 1
}

# out <key> <value>: print key=value and append it to GITHUB_OUTPUT.
out() {
  [[ "$2" != *$'\n'* ]] || die "output ${1} contains a newline"
  printf '%s=%s\n' "$1" "$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT}"; fi
}

summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then printf '%s\n' "$*" >> "${GITHUB_STEP_SUMMARY}"; fi
}

# ---------------------------------------------------------------------------
# Version and tag selection (pure, unit tested)
# ---------------------------------------------------------------------------

# xs_version_of <tag>: print X.Y.Z when the tag is a stable release tag.
xs_version_of() {
  local t="$1"
  [[ "${t}" != *$'\n'* ]] || return 1
  # shellcheck disable=SC2154 # XS_TAG_REGEX is an ERE on purpose
  [[ "${t}" =~ ${XS_TAG_REGEX} ]] || return 1
  printf '%s.%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
}

# xs_tag_of <X.Y.Z>: print the tag name for a version.
xs_tag_of() { printf '%s\n' "${XS_TAG_FORMAT//%s/$1}"; }

# xs_sorted_stable: tags on stdin -> "<version> <tag>" lines, stable only,
# ascending by version.
xs_sorted_stable() {
  local t v
  while IFS= read -r t; do
    v="$(xs_version_of "${t}")" || continue
    printf '%s %s\n' "${v}" "${t}"
  done | LC_ALL=C sort -t. -k1,1n -k2,2n -k3,3n -u
}

# xs_highest_stable: tags on stdin -> the highest stable tag (empty if none).
xs_highest_stable() {
  xs_sorted_stable | awk 'END { print $2 }'
}

# xs_ver_gt <a> <b>: true when version a is higher than b.
xs_ver_gt() {
  [[ "$1" != "$2" ]] || return 1
  [[ "$(printf '%s\n%s\n' "$1" "$2" | LC_ALL=C sort -t. -k1,1n -k2,2n -k3,3n | tail -n1)" == "$1" ]]
}

# with_chart <chart> <command...>: run a command with the tag regex and tag name
# format of one chart (<chart>-X.Y.Z). Chart tags of other charts, weekly tags and
# pre-releases do not match.
with_chart() {
  local c="$1"
  shift
  local XS_TAG_REGEX="^${c}-([0-9]+)\\.([0-9]+)\\.([0-9]+)\$" XS_TAG_FORMAT="${c}-%s"
  "$@"
}

# chart_field <rev> <chart> <field>: top-level scalar of charts/<chart>/Chart.yaml
# at <rev> (a commit or a tree).
chart_field() {
  git show "$1:charts/$2/Chart.yaml" | sed -n -E "s/^$3: *[\"']?([^\"'#]*[^\"' #])[\"']? *(#.*)?\$/\\1/p" | head -n1
}

# chart_current_tag <rev> <chart>: the upstream chart tag the chart at <rev> is
# built on: the chart version without the +xs.N build metadata.
chart_current_tag() {
  local v
  v="$(chart_field "$1" "$2" version)"
  [[ -n "${v}" ]] || die "no version in charts/$2/Chart.yaml at $1"
  printf '%s-%s\n' "$2" "${v%%+*}"
}

# xs_chart_app <chart> <tag>: appVersion of a chart tag.
xs_chart_app() { chart_field "refs/tags/$2" "$1" appVersion; }

# Engine lookups are cached per engine and appVersion for the life of the run (the
# cache directory is created once, so command substitutions share it).
XS_ENGINE_CACHE="${XS_ENGINE_CACHE:-$(mktemp -d)}"
export XS_ENGINE_CACHE

# xs_engine_n <engine> <appVersion>: prints "<N> <digest>" for the highest N for which
# the engine image <appVersion>-xs.N is released and verified, nothing when there is
# none. XS_ENGINE_MOCK ("engine:app:N ...") replaces the registry lookup, and only when
# XS_MOCK_OK=1, which only the rehearsal sets; a mocked digest is all zeros.
xs_engine_n() {
  local engine="$1" app="$2" m e a n cf r
  if [[ -n "${XS_ENGINE_MOCK+x}" && "${XS_MOCK_OK:-}" == 1 ]]; then
    for m in ${XS_ENGINE_MOCK}; do
      IFS=: read -r e a n <<<"${m}"
      if [[ "${e}" == "${engine}" && "${a}" == "${app}" ]]; then printf '%s sha256:%064d\n' "${n}" 0; fi
    done
    return 0
  fi
  cf="${XS_ENGINE_CACHE}/${engine}-${app}"
  if [[ -f "${cf}" ]]; then
    cat "${cf}"
    return 0
  fi
  r="$(xs_engine_live "${engine}" "${app}")"
  printf '%s' "${r}" > "${cf}"
  if [[ -n "${r}" ]]; then printf '%s\n' "${r}"; fi
}

# xs_engine_identity <engine>: the exact certificate identity of the engine release.
xs_engine_identity() { printf 'https://github.com/%s/%s/.github/workflows/xs-release.yml@refs/heads/main\n' "${XS_ENGINE_ORG}" "$1"; }

# xs_cosign_ok <ref@digest> <identity>: true when the exact release identity signed
# the image. A missing or foreign signature is false; any other failure dies.
xs_cosign_ok() {
  local err
  err="$(mktemp)"
  if cosign verify --certificate-identity "$2" --certificate-oidc-issuer "${XS_ENGINE_ISSUER}" "$1" > /dev/null 2> "${err}"; then return 0; fi
  if grep -q -i -E 'no signatures found|no matching signatures|none of the expected identities matched|expected identity' "${err}"; then return 1; fi
  cat "${err}" >&2
  die "cosign verify of $1 failed"
}

# xs_attest_ok <ref@digest> <engine>: true when the provenance attestation of the image
# was made by the exact release identity of the engine repository. A missing or foreign
# attestation is false; any other failure dies.
xs_attest_ok() {
  local err
  err="$(mktemp)"
  if gh attestation verify "oci://$1" --repo "${XS_ENGINE_ORG}/$2" --cert-identity "$(xs_engine_identity "$2")" > /dev/null 2> "${err}"; then return 0; fi
  if grep -q -i -E 'no attestations found|verifying with issuer|verification failed|failed to verify the attestation|does not match' "${err}"; then return 1; fi
  cat "${err}" >&2
  die "attestation verify of $1 failed"
}

# xs_engine_trusted <engine> <tag-or-digest-ref-base> <digest>: true when the digest is
# signed and attested by the engine release identity.
xs_engine_trusted() {
  local engine="$1" repo="$2" digest="$3"
  xs_cosign_ok "${repo}@${digest}" "$(xs_engine_identity "${engine}")" && xs_attest_ok "${repo}@${digest}" "${engine}"
}

# xs_engine_live <engine> <appVersion>: registry lookup. Tags are mutable, so the digest
# is resolved first and trust is established on the digest (cosign signature and
# provenance attestation, exact release identity). The Packages API tells a package
# that does not exist yet (404) from one we cannot see: a denied or rate limited
# request, or a failing registry, fails the run. Prints "<N> <digest>".
xs_engine_live() {
  local engine="$1" app="$2" repo tags err t n digest app_re="${2//./\\.}"
  repo="${XS_ENGINE_REGISTRY}/${XS_ENGINE_ORG}/${engine}"
  err="$(mktemp)"
  if [[ "${XS_ENGINE_PKG_API:-yes}" == yes ]]; then
    if ! gh api "orgs/${XS_ENGINE_ORG}/packages/container/${engine}" > /dev/null 2> "${err}"; then
      if grep -q 'HTTP 404' "${err}"; then
        log "no package ${repo} yet"
        return 0
      fi
      cat "${err}" >&2
      die "could not look up the package ${engine}"
    fi
  fi
  if ! tags="$(crane ls "${repo}" 2> "${err}")"; then
    cat "${err}" >&2
    die "could not list ${repo}"
  fi
  local -a ns=()
  while IFS= read -r t; do
    if [[ "${t}" =~ ^${app_re}-xs\.(0|[1-9][0-9]*)$ ]]; then ns+=("${BASH_REMATCH[1]}"); fi
  done <<<"${tags}"
  ((${#ns[@]} > 0)) || return 0
  while IFS= read -r n; do
    digest="$(crane digest "${repo}:${app}-xs.${n}")" || die "could not resolve ${repo}:${app}-xs.${n}"
    if xs_engine_trusted "${engine}" "${repo}" "${digest}"; then
      printf '%s %s\n' "${n}" "${digest}"
      return 0
    fi
    log "${repo}:${app}-xs.${n} is not signed and attested by $(xs_engine_identity "${engine}")"
  done < <(printf '%s\n' "${ns[@]}" | LC_ALL=C sort -rn)
}

# xs_pick <chart> <current-tag> [--cap TAG]
# stdin: every tag. The target is the newest stable chart tag above the current one
# whose appVersion has a released, verified engine image. Prints key=value lines:
# chart, current, target (empty when none), app, engine, skipped, reason.
xs_pick() {
  local chart="$1" current="$2" cap="" cur_v cap_v="" v t app n dg target="" tapp="" engine="" digest="" skipped="" downgrades="" cur_app
  shift 2
  while (($#)); do
    case "$1" in
      --cap) cap="$2"; shift 2 ;;
      *) die "pick: unknown option $1" ;;
    esac
  done
  local XS_TAG_REGEX="^${chart}-([0-9]+)\\.([0-9]+)\\.([0-9]+)\$" XS_TAG_FORMAT="${chart}-%s"
  cur_v="$(xs_version_of "${current}")" || die "current tag ${current} is not a stable ${chart} chart tag"
  if [[ -n "${cap}" ]]; then cap_v="$(xs_version_of "${cap}")" || die "cap tag ${cap} is not a stable ${chart} chart tag"; fi
  cur_app="$(xs_chart_app "${chart}" "${current}")"
  while read -r v t; do
    xs_ver_gt "${v}" "${cur_v}" || break
    if [[ -n "${cap_v}" ]] && xs_ver_gt "${v}" "${cap_v}"; then continue; fi
    app="$(xs_chart_app "${chart}" "${t}")"
    [[ "${app}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    # An appVersion below the one main runs is a downgrade of the engine: never a target.
    if [[ "${cur_app}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && xs_ver_gt "${cur_app}" "${app}"; then
      downgrades+="${downgrades:+ }${t}"
      continue
    fi
    read -r n dg <<<"$(xs_engine_n "${XS_CHART_ENGINE[${chart}]}" "${app}")"
    if [[ -n "${n}" ]]; then
      target="${t}"
      tapp="${app}"
      engine="${app}-xs.${n}"
      digest="${dg}"
      break
    fi
    skipped+="${skipped:+ }${t}"
  done < <(xs_sorted_stable | tac)
  local reason
  if [[ -n "${target}" ]]; then
    reason="${chart}: ${target} (appVersion ${tapp}, engine ${engine}) is newer than ${current}"
  elif [[ -n "${skipped}" ]]; then
    reason="${chart}: stays at ${current}, no released engine for ${skipped}"
    if [[ -n "${downgrades}" ]]; then reason+="; appVersion below ${cur_app} for ${downgrades}"; fi
  elif [[ -n "${downgrades}" ]]; then
    reason="${chart}: stays at ${current}, appVersion below ${cur_app} for ${downgrades}"
  else
    reason="${chart}: stays at ${current}, no newer chart tag"
  fi
  printf 'chart=%s\ncurrent=%s\ntarget=%s\napp=%s\nengine=%s\ndigest=%s\nskipped=%s\ndowngrades=%s\nreason=%s\n' \
    "${chart}" "${current}" "${target}" "${tapp}" "${engine}" "${digest}" "${skipped}" "${downgrades}" "${reason}"
}

# Heads. Chart heads are sync/<entry>[_<entry>...] where an entry is <chart>-X.Y.Z (a
# chart bump) or <chart>-X.Y.Z-xs.<m>-e<N> (a rebuild of that chart tag at +xs.<m> with
# engine build N). Upstream-only refreshes are sync/upstream-YYYYMMDD. Any other name
# under sync/ is not ours and is never touched.
xs_head_re() {
  local alt entry
  alt="$(IFS='|'; printf '%s' "${XS_CHARTS[*]}")"
  entry="(${alt})-[0-9]+\\.[0-9]+\\.[0-9]+(-xs\\.[0-9]+-e[0-9]+)?"
  printf '^sync/(%s(_%s)*|upstream-[0-9]{8})$' "${entry}" "${entry}"
}

# xs_bot_head <head>: true when the head name is in a format this sync creates.
xs_bot_head() {
  local re
  re="$(xs_head_re)"
  [[ "$1" =~ ${re} ]]
}

# xs_head <entry>...: sync branch for a set of chart entries.
xs_head() {
  local IFS=_
  printf 'sync/%s\n' "$*"
}

# xs_head_keys <head>: "<chart> <X.Y.Z.m.e>" per entry of a chart head.
xs_head_keys() {
  local e chart rest
  local -a entries
  IFS=_ read -r -a entries <<<"${1#sync/}"
  for e in "${entries[@]}"; do
    for chart in "${XS_CHARTS[@]}"; do
      [[ "${e}" == "${chart}-"* ]] || continue
      rest="${e#"${chart}"-}"
      if [[ "${rest}" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-xs\.([0-9]+)-e([0-9]+)$ ]]; then
        printf '%s %s.%s.%s\n' "${chart}" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
      else
        printf '%s %s.0.0\n' "${chart}" "${rest}"
      fi
      break
    done
  done
}

# xs_key_gt <a> <b>: true when key a (X.Y.Z.m.e) is above key b.
xs_key_gt() {
  [[ "$1" != "$2" ]] || return 1
  [[ "$(printf '%s\n%s\n' "$1" "$2" | LC_ALL=C sort -t. -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n | tail -n1)" == "$1" ]]
}

# xs_head_superseded <old-head> <new-head> <current-keys>: true when the old bot head is
# covered by the new one: for every chart in it, the new head carries that chart at an
# equal or higher key, or (when the new head does not carry it) main is already at an
# equal or higher key. Current keys are "chart=X.Y.Z.m.e" words.
xs_head_superseded() {
  local old="$1" new="$2" cur="$3" c k nk ck
  if [[ "${old}" == sync/upstream-* ]]; then
    [[ "${new}" == sync/* && "${new}" != sync/upstream-* ]]
    return
  fi
  while read -r c k; do
    nk="$(xs_head_keys "${new}" | awk -v c="${c}" '$1 == c { print $2 }')"
    if [[ -n "${nk}" ]]; then
      ! xs_key_gt "${k}" "${nk}" || return 1
    else
      ck=""
      local w
      for w in ${cur}; do [[ "${w}" == "${c}="* ]] && ck="${w#*=}"; done
      [[ -n "${ck}" ]] && ! xs_key_gt "${k}" "${ck}" || return 1
    fi
  done < <(xs_head_keys "${old}")
  return 0
}

# xs_decide <head> <current-keys> [open-pr-head...]: head is empty when nothing is to be
# synced. Prints proceed, reason, head, supersede. Only bot heads are considered, and an
# open head is superseded only when the new head covers it (xs_head_superseded).
xs_decide() {
  local head="$1" cur="$2" h proceed=false open_pr=false supersede="" reason="no chart has a newer release with a released engine"
  shift 2
  if [[ -n "${head}" ]]; then
    proceed=true
    reason="sync for ${head#sync/}"
  fi
  for h in "$@"; do
    xs_bot_head "${h}" || continue
    if [[ "${h}" == "${head}" ]]; then
      proceed=false
      open_pr=true
      reason="a sync PR from ${head} is already open"
    elif [[ "${head}" == sync/upstream-* && "${h}" == sync/upstream-* ]]; then
      # One upstream refresh at a time: the open one is refreshed in place.
      proceed=false
      open_pr=true
      head="${h}"
      reason="an upstream refresh PR from ${h} is already open"
    elif [[ -n "${head}" ]] && xs_head_superseded "${h}" "${head}" "${cur}"; then
      supersede+="${supersede:+ }${h}"
    fi
  done
  printf 'proceed=%s\nopen_pr=%s\nreason=%s\nhead=%s\nsupersede=%s\n' "${proceed}" "${open_pr}" "${reason}" "${head}" "${supersede}"
}

# xs_path_allowed <path>: true when the path matches a patch path rule.
xs_path_allowed() {
  local p="$1" rule
  for rule in "${XS_PATCH_PATHS[@]}"; do
    # shellcheck disable=SC2254 # the rule is a glob on purpose
    case "${p}" in ${rule}) return 0 ;; esac
  done
  return 1
}

# xs_own_heads: stdin is `gh pr list --json headRefName,isCrossRepository`.
# Prints the head branches of PRs from this repository only. A fork can name its
# branch sync/<tag>; those PRs must never block or be touched by the sync.
xs_own_heads() {
  jq -r '.[] | select(.isCrossRepository == false) | .headRefName'
}

# xs_prev_tag <tag>: stdin is every tag. Prints the highest stable tag below
# <tag>, preferring the same major.minor line.
xs_prev_tag() {
  local tv v t same="" any=""
  tv="$(xs_version_of "$1")" || die "$1 is not a stable release tag"
  while read -r v t; do
    xs_ver_gt "${tv}" "${v}" || continue
    any="${t}"
    if [[ "${v}" == "${tv%.*}".* ]]; then same="${t}"; fi
  done < <(xs_sorted_stable)
  printf '%s\n' "${same:-${any}}"
}

# xs_md_paths [plain]: NUL separated paths on stdin -> bullet list. Control
# characters and backticks are neutralised so a path cannot break the markdown;
# paths go into code spans so @ and # do not mention or link anything.
xs_md_paths() {
  local p bt='`' sq="'"
  while IFS= read -r -d '' p; do
    p="${p//[[:cntrl:]]/?}"
    p="${p//${bt}/${sq}}"
    if [[ "${1:-}" == plain ]]; then printf -- '- %s\n' "${p}"; else printf -- '- `%s`\n' "${p}"; fi
  done
}

# xs_content_matches <tag> <commit>: true when every path that differs between
# the tag and the commit is a patch path, i.e. the commit already holds the
# tag's content.
xs_content_matches() {
  local p
  while IFS= read -r -d '' p; do
    xs_path_allowed "${p}" || return 1
  done < <(git diff --no-renames --name-only -z "$1" "$2")
  return 0
}

# retry <attempts> <command>...: run the command, sleeping between attempts.
retry() {
  local n="$1" i=1
  shift
  until "$@"; do
    ((i < n)) || return 1
    sleep $((i * ${XS_RETRY_SLEEP:-5}))
    i=$((i + 1))
  done
}

# xs_body_fill <body-file> <fill-file>: replace the text between the flag diff
# markers in the body with the fill file. Prints the new body.
xs_body_fill() {
  local body="$1" fill="$2"
  grep -qxF "${XS_FLAG_BEGIN}" "${body}" || die "body has no flag diff placeholder"
  awk -v b="${XS_FLAG_BEGIN}" -v e="${XS_FLAG_END}" -v f="${fill}" '
    $0 == b { print; while ((getline line < f) > 0) print line; skip = 1; next }
    $0 == e { skip = 0 }
    !skip { print }
  ' "${body}"
}

# ---------------------------------------------------------------------------
# Git and GitHub helpers
# ---------------------------------------------------------------------------

repo_slug() { printf '%s\n' "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"; }

# git_auth_args: git -c options that authenticate https pushes with XS_PUSH_TOKEN.
git_push() {
  local hdr
  hdr="$(printf 'x-access-token:%s' "${XS_PUSH_TOKEN:?XS_PUSH_TOKEN required}" | base64 -w0)"
  echo "::add-mask::${hdr}"
  git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic ${hdr}" push "$@"
}

ensure_upstream_remote() {
  if git remote get-url "${XS_UPSTREAM_REMOTE}" > /dev/null 2>&1; then
    git remote set-url "${XS_UPSTREAM_REMOTE}" "${XS_UPSTREAM_URL}"
  else
    git remote add "${XS_UPSTREAM_REMOTE}" "${XS_UPSTREAM_URL}"
  fi
}

ensure_label() {
  gh label create "$1" --color "$2" --description "$3" --force > /dev/null
}

# ---------------------------------------------------------------------------
# mirror
# ---------------------------------------------------------------------------
# Limits, by design: a tag that already exists on origin is never moved, so a
# tag upstream re-points stays at the old commit here; an upstream branch that
# is deleted stays stale under upstream/. Both are rare and need a human.

# mirror_batches <fetch-specs> <push-specs> <names>: arrays by name. Fetch and
# push in batches of 200 (GitHub rejects larger tag pushes). A failed batch is
# retried, then retried ref by ref; refs that still fail go to MIRROR_FAILED.
MIRROR_FAILED=()
mirror_batches() {
  local -n _f="$1" _p="$2" _n="$3"
  local i j
  for ((i = 0; i < ${#_f[@]}; i += 200)); do
    local -a bf=("${_f[@]:i:200}") bp=("${_p[@]:i:200}") bn=("${_n[@]:i:200}")
    if retry 3 git fetch --no-tags "${XS_UPSTREAM_REMOTE}" "${bf[@]}" && retry 3 git_push origin "${bp[@]}"; then
      continue
    fi
    log "batch failed, retrying ref by ref"
    for ((j = 0; j < ${#bf[@]}; j++)); do
      if retry 2 git fetch --no-tags "${XS_UPSTREAM_REMOTE}" "${bf[j]}" && retry 2 git_push origin "${bp[j]}"; then
        :
      else
        MIRROR_FAILED+=("${bn[j]}")
      fi
    done
  done
}

# mirror_ns_check <ref>...: upstream main and the given refs (the tags mirrored in
# this run) must not contain paths in the xs namespace. They are mirrored anyway
# (mirrors are data), but pushing a branch that holds such a workflow can run it
# with the push's context, so the run fails and a human looks. Main is checked on
# every run, so the failure repeats until upstream drops the path.
mirror_ns_check() {
  local ref bad=0 list
  retry 3 git fetch --no-tags "${XS_UPSTREAM_REMOTE}" "+refs/heads/main:refs/remotes/${XS_UPSTREAM_REMOTE}/main" || die "cannot fetch upstream main"
  for ref in "refs/remotes/${XS_UPSTREAM_REMOTE}/main" "$@"; do
    git rev-parse --verify --quiet "${ref}^{commit}" > /dev/null || continue
    list="$(xs_ns_violations "${ref}")" || die "cannot list the tree of ${ref}"
    [[ -n "${list}" ]] || continue
    bad=$((bad + 1))
    printf '::error::upstream %s holds paths in the xs namespace: %s\n' "${ref#refs/}" "$(head -n 10 <<<"${list}" | tr '\n' ';')" >&2
    summary "upstream ${ref#refs/} holds paths in the xs namespace (mirrored anyway, review them):"
    summary "$(head -n 20 <<<"${list}" | sed 's/^/- /')"
  done
  ((bad == 0))
}

cmd_mirror() {
  local dry=false
  [[ "${1:-}" == "--dry-run" ]] && dry=true
  ensure_upstream_remote

  local up_heads up_tags or_heads or_tags
  up_heads="$(mktemp)"
  up_tags="$(mktemp)"
  or_heads="$(mktemp)"
  or_tags="$(mktemp)"
  retry 3 git ls-remote --heads "${XS_UPSTREAM_REMOTE}" > "${up_heads}"
  retry 3 git ls-remote --tags --refs "${XS_UPSTREAM_REMOTE}" > "${up_tags}"
  retry 3 git ls-remote --heads origin 'refs/heads/upstream/*' > "${or_heads}"
  retry 3 git ls-remote --tags --refs origin > "${or_tags}"

  # Branches: upstream <b> -> origin upstream/<b>, only when the sha differs.
  local sha ref name cur
  local -a b_fetch=() b_push=() b_names=() ns_refs=()
  while read -r sha ref; do
    name="${ref#refs/heads/}"
    [[ "${name}" =~ ${XS_BRANCH_REGEX} ]] || continue
    cur="$(awk -v r="refs/heads/upstream/${name}" '$2 == r { print $1 }' "${or_heads}")"
    [[ "${cur}" != "${sha}" ]] || continue
    b_fetch+=("+refs/heads/${name}:refs/remotes/${XS_UPSTREAM_REMOTE}/${name}")
    b_push+=("+refs/remotes/${XS_UPSTREAM_REMOTE}/${name}:refs/heads/upstream/${name}")
    b_names+=("branch ${name}")
    echo "branch ${name}: ${cur:-none} -> ${sha}"
  done < "${up_heads}"

  # Tags: names upstream has and origin lacks. Our own -xs. tags are never touched.
  local -a t_fetch=() t_push=() t_names=()
  while read -r sha ref; do
    name="${ref#refs/tags/}"
    if [[ "${name}" == *-xs.* || "${name}" == *+xs.* ]]; then continue; fi
    if awk -v r="${ref}" '$2 == r { found = 1 } END { exit !found }' "${or_tags}"; then continue; fi
    t_fetch+=("refs/tags/${name}:refs/tags/${name}")
    t_push+=("refs/tags/${name}:refs/tags/${name}") # no force: existing tags are never moved
    t_names+=("tag ${name}")
    ns_refs+=("refs/tags/${name}")
  done < "${up_tags}"
  echo "new tags: ${#t_names[@]}"
  if ((${#t_names[@]} > 0)); then printf '  %s\n' "${t_names[@]:0:40}"; fi
  if ((${#t_names[@]} > 40)); then echo "  ... and $((${#t_names[@]} - 40)) more"; fi

  summary "### mirror (dry run: ${dry})"
  summary "- branches to push: ${#b_names[@]}"
  summary "- tags to push: ${#t_names[@]}"

  if [[ "${dry}" == true ]]; then
    echo "dry run: nothing pushed"
    return 0
  fi

  # Safety: the destinations are only refs/heads/upstream/* and refs/tags/*.
  local s
  for s in "${b_push[@]}"; do
    [[ "${s#*:}" == refs/heads/upstream/* ]] || die "refusing destination ${s#*:}"
  done

  mirror_batches b_fetch b_push b_names
  mirror_batches t_fetch t_push t_names
  local rc=0
  if ((${#MIRROR_FAILED[@]} > 0)); then
    printf '::error::mirror failed for: %s\n' "${MIRROR_FAILED[*]}" >&2
    summary "mirror failed for: ${MIRROR_FAILED[*]}"
    rc=1
  fi
  mirror_ns_check "${ns_refs[@]}" || rc=1
  ((rc == 0)) || return 1
  echo "mirror done"
}

# open-heads <out-file>: head branches of open PRs that come from this repository.
cmd_open_heads() {
  gh pr list --state open --limit 1000 --json headRefName,isCrossRepository | xs_own_heads > "${1:?out file required}"
}

# ---------------------------------------------------------------------------
# ghcr-login: log crane and cosign in to the engine registry with the job token
# (packages: read), so a package that exists is listed and a denied request is an error.
# ---------------------------------------------------------------------------
cmd_ghcr_login() {
  crane auth login "${XS_ENGINE_REGISTRY}" -u "${GITHUB_ACTOR:-xs-sync}" --password-stdin <<<"${GH_TOKEN:?GH_TOKEN required}"
}

# ---------------------------------------------------------------------------
# engines: read-only look at the engine releases (CI proof of the registry access)
# ---------------------------------------------------------------------------
cmd_engines() {
  local base="origin/${XS_MAIN_BRANCH}" chart app n dg
  [[ "${1:-}" != --base ]] || base="$2"
  for chart in "${XS_CHARTS[@]}"; do
    app="$(chart_field "${base}" "${chart}" appVersion)"
    read -r n dg <<<"$(xs_engine_n "${XS_CHART_ENGINE[${chart}]}" "${app}")"
    if [[ -n "${n}" ]]; then
      echo "${chart}: engine ${XS_CHART_ENGINE[${chart}]} ${app}-xs.${n} is ${dg}"
      summary "- ${chart}: engine \`${app}-xs.${n}\` verified at \`${dg}\`"
    else
      echo "${chart}: no verified engine release for ${app}"
      summary "- ${chart}: no verified engine release for ${app}"
    fi
  done
}

# ---------------------------------------------------------------------------
# detect
# ---------------------------------------------------------------------------
# upstream_base <base> <upstream>: the upstream main commit that <base>'s tree
# (outside the charts) is built on, and a check that nothing outside the patch set
# differs from it. A squash merge of a sync PR drops the upstream parent and shows
# up here.
upstream_base() {
  local base="$1" upstream="$2" ub p
  ub="$(git merge-base "${base}" "${upstream}")" || die "${base} and ${upstream} share no history"
  local -a ex=()
  local c
  for c in "${XS_CHARTS[@]}"; do ex+=(":!charts/${c}"); done
  while IFS= read -r -d '' p; do
    xs_path_allowed "${p}" || die "${p} differs between upstream ${ub} and ${base} and is not a patch path (a squash or rebase merge of a sync PR? Merge sync PRs with a merge commit)"
  done < <(git diff --no-renames --name-only -z "${ub}" "${base}" -- . "${ex[@]}")
  printf '%s\n' "${ub}"
}

cmd_detect() {
  local base="origin/${XS_MAIN_BRANCH}" upstream="origin/upstream/main" heads_file=""
  local -a caps=()
  while (($#)); do
    case "$1" in
      --base) base="$2"; shift 2 ;;
      --upstream) upstream="$2"; shift 2 ;;
      --open-heads) heads_file="$2"; shift 2 ;;
      --cap) caps+=("$2"); shift 2 ;;
      *) die "detect: unknown option $1" ;;
    esac
  done
  local ub
  ub="$(upstream_base "${base}" "${upstream}")" || exit 1
  local -a heads=()
  if [[ -n "${heads_file}" ]]; then mapfile -t heads < "${heads_file}"; fi
  local chart cur res k v c capopt
  local -a bumps=() targets=() notes=() curkeys=()
  local target engine digest reason
  for chart in "${XS_CHARTS[@]}"; do
    cur="$(chart_current_tag "${base}" "${chart}")"
    git rev-parse --verify --quiet "refs/tags/${cur}^{commit}" > /dev/null || die "${base} is on ${cur} but that tag is missing"
    capopt=()
    for c in "${caps[@]}"; do
      if [[ "${c}" == "${chart}-"* ]]; then capopt=(--cap "${c}"); fi
    done
    res="$(git tag --list "${chart}-*" | xs_pick "${chart}" "${cur}" "${capopt[@]}")"
    target="" engine="" digest="" reason=""
    while IFS='=' read -r k v; do
      [[ "${k}" == target ]] && target="${v}"
      [[ "${k}" == engine ]] && engine="${v}"
      [[ "${k}" == digest ]] && digest="${v}"
      [[ "${k}" == reason ]] && reason="${v}"
    done <<<"${res}"
    local app cur_engine cur_n m n dg
    app="$(chart_field "${base}" "${chart}" appVersion)"
    cur_engine="$(chart_engine_tag "${base}" "${chart}")"
    cur_n="${cur_engine##*-xs.}"
    m="$(chart_field "${base}" "${chart}" version)"
    m="${m##*+xs.}"
    [[ "${cur_engine}" == "${app}-xs."* && "${cur_n}" =~ ^[0-9]+$ && "${m}" =~ ^[0-9]+$ ]] || die "${chart}: engineTag ${cur_engine} or version metadata on ${base} is not <appVersion>-xs.N / +xs.M"
    curkeys+=("${chart}=${cur#"${chart}"-}.${m}.${cur_n}")
    if [[ -z "${target}" ]]; then
      # No newer chart tag with an engine: a newer verified engine build for the
      # chart's own appVersion is a rebuild of this chart tag (+xs.<m+1>).
      read -r n dg <<<"$(xs_engine_n "${XS_CHART_ENGINE[${chart}]}" "${app}")"
      if [[ -n "${n}" ]] && ((n > cur_n)); then
        engine="${app}-xs.${n}"
        reason="${chart}: ${cur} rebuilt as +xs.$((m + 1)) with engine ${engine} (was ${cur_engine})"
        bumps+=("${chart}:${cur}:${engine}@${dg}")
        targets+=("${cur}-xs.$((m + 1))-e${n}")
      fi
    else
      bumps+=("${chart}:${target}:${engine}@${digest}")
      targets+=("${target}")
    fi
    echo "${reason}"
    notes+=("${reason}")
  done
  local head="" drift=false behind days
  if ((${#targets[@]} > 0)); then
    head="$(xs_head "${targets[@]}")"
  else
    # Upstream drift: with no chart to move, main still follows upstream main when it
    # falls far behind (the other charts, shared files and tooling).
    behind="$(git rev-list --count "${ub}..${upstream}")"
    days=$((($(git log -1 --format=%ct "${upstream}") - $(git log -1 --format=%ct "${ub}")) / 86400))
    if ((behind > XS_DRIFT_COMMITS || days > XS_DRIFT_DAYS)); then
      drift=true
      head="sync/upstream-${XS_TODAY:-$(date -u +%Y%m%d)}"
      notes+=("upstream main is ${behind} commits and ${days} days ahead of main's base: refresh the base")
      echo "${notes[-1]}"
    fi
  fi
  local result
  result="$(xs_decide "${head}" "${curkeys[*]}" "${heads[@]}")"
  while IFS='=' read -r k v; do out "${k}" "${v}"; done <<<"${result}"
  out bumps "${bumps[*]}"
  out drift "${drift}"
  out upstream_commit "$(git rev-parse "${upstream}^{commit}")"
  out upstream_base "${ub}"
  summary "### detect"
  local x
  for x in "${notes[@]}"; do summary "- ${x}"; done
  summary "$(grep '^reason=' <<<"${result}" | cut -d= -f2-)"
}

# ---------------------------------------------------------------------------
# API commit helpers
# ---------------------------------------------------------------------------

# api_call <method> <endpoint> <json-file>: call the API and print the body.
# Throttling (429, secondary rate limits) and 5xx are retried with a growing
# backoff; anything else fails at once.
api_call() {
  local method="$1" endpoint="$2" input="$3" attempt=1 err body
  err="$(mktemp)"
  while :; do
    if body="$(gh api --method "${method}" "${endpoint}" --input "${input}" 2> "${err}")"; then
      printf '%s\n' "${body}"
      return 0
    fi
    if grep -q -i -E 'HTTP 429|HTTP 5[0-9][0-9]|rate limit|secondary|abuse detection|retry after' "${err}" && ((attempt < 6)); then
      log "API ${method} ${endpoint} throttled or failed (attempt ${attempt}), backing off"
      sleep $((attempt * attempt * ${XS_RETRY_SLEEP:-5}))
      attempt=$((attempt + 1))
      continue
    fi
    cat "${err}" >&2
    return 1
  done
}

# api_plan <base-tree> <result-tree>: one JSON line per changed path on stdout:
# {path, mode, type, sha, blob}. sha is null for a deletion, blob is true when the
# content is new and needs a blob (false for a mode-only change). Renames are
# plain delete plus add. Submodules, unusual modes and file/directory swaps fail.
api_plan() {
  local base="$1" result="$2" meta path omode nmode osha nsha status blob
  local -a deleted=() added=()
  while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
    read -r omode nmode osha nsha status <<<"${meta#:}"
    case "${status}" in
      D)
        [[ "${omode}" != 160000 ]] || die "submodule removal at ${path} is not supported"
        deleted+=("${path}")
        jq -cn --arg p "${path}" --arg m "${omode}" '{path:$p,mode:$m,type:"blob",sha:null,blob:false}'
        ;;
      A | M | T)
        case "${nmode}" in
          100644 | 100755 | 120000) ;;
          160000) die "submodule change at ${path} is not supported" ;;
          *) die "unsupported file mode ${nmode} at ${path}" ;;
        esac
        added+=("${path}")
        blob=true
        if [[ "${osha}" == "${nsha}" ]]; then blob=false; fi
        jq -cn --arg p "${path}" --arg m "${nmode}" --arg s "${nsha}" --argjson b "${blob}" \
          '{path:$p,mode:$m,type:"blob",sha:$s,blob:$b}'
        ;;
      *) die "unexpected diff status ${status} at ${path}" ;;
    esac
  done < <(git diff-tree -r -z --no-renames --raw "${base}" "${result}")

  # A path that turns from file to directory or back cannot go through one
  # tree request with a base tree.
  local -A dset=() aset=()
  local x q
  for x in "${deleted[@]}"; do dset["${x}"]=1; done
  for x in "${added[@]}"; do aset["${x}"]=1; done
  for x in "${added[@]}"; do
    q="${x}"
    while [[ "${q}" == */* ]]; do
      q="${q%/*}"
      [[ -z "${dset[${q}]:-}" ]] || die "file to directory change at ${q} is not supported"
    done
  done
  for x in "${deleted[@]}"; do
    q="${x}"
    while [[ "${q}" == */* ]]; do
      q="${q%/*}"
      [[ -z "${aset[${q}]:-}" ]] || die "directory to file change at ${q} is not supported"
    done
  done
}

# api_commit <base-tree-of-parent> <result-tree> <message-file> <parent>...
# Creates blobs and a tree for the difference between <base-tree-of-parent> and
# <result-tree>, then a commit with the given parents. Prints the commit sha.
# The commit has no author or committer set, so GitHub signs it as the App.
api_commit() {
  local base_tree="$1" result_tree="$2" msg_file="$3"
  shift 3
  local repo tmp line sha path nsha tree_sha n=0
  repo="$(repo_slug)"
  tmp="$(mktemp -d)"
  api_plan "${base_tree}" "${result_tree}" > "${tmp}/plan"
  : > "${tmp}/entries"
  while IFS= read -r line; do
    n=$((n + 1))
    if [[ "$(jq -r .blob <<<"${line}")" == true ]]; then
      nsha="$(jq -r .sha <<<"${line}")"
      path="$(jq -r .path <<<"${line}")"
      git cat-file blob "${nsha}" | base64 -w0 > "${tmp}/b64"
      jq -n --rawfile c "${tmp}/b64" '{content:$c,encoding:"base64"}' > "${tmp}/blob.json"
      sha="$(api_call POST "repos/${repo}/git/blobs" "${tmp}/blob.json" | jq -r .sha)"
      [[ "${sha}" == "${nsha}" ]] || die "blob ${path}: API sha ${sha} != local ${nsha}"
    fi
    jq -c 'del(.blob)' <<<"${line}" >> "${tmp}/entries"
  done < "${tmp}/plan"

  if ((n == 0)); then
    tree_sha="${base_tree}"
  else
    jq -s --arg b "${base_tree}" '{base_tree:$b,tree:.}' "${tmp}/entries" > "${tmp}/tree.json"
    tree_sha="$(api_call POST "repos/${repo}/git/trees" "${tmp}/tree.json" | jq -r .sha)"
  fi
  [[ "${tree_sha}" == "${result_tree}" ]] || die "API tree ${tree_sha} != local tree ${result_tree}"

  local parents_json
  parents_json="$(printf '%s\n' "$@" | jq -R . | jq -sc .)"
  jq -n --rawfile m "${msg_file}" --arg t "${tree_sha}" --argjson p "${parents_json}" \
    '{message:$m,tree:$t,parents:$p}' > "${tmp}/commit.json"
  api_call POST "repos/${repo}/git/commits" "${tmp}/commit.json" | jq -r .sha
  rm -rf "${tmp}"
}

branch_name_ok() { [[ "$1" =~ ^(sync|rehearsal-sync)/[A-Za-z0-9._-]+$ ]]; }

# api_ref_set <branch> <sha>: create the branch, or move it when it exists. Callers
# run branch_guard first. Only sync/* and rehearsal-sync/* are ever written.
api_ref_set() {
  local branch="$1" sha="$2" repo err
  branch_name_ok "${branch}" || die "refusing to write branch ${branch}"
  repo="$(repo_slug)"
  err="$(mktemp)"
  if gh api --method POST "repos/${repo}/git/refs" -f "ref=refs/heads/${branch}" -f "sha=${sha}" > /dev/null 2> "${err}"; then
    return 0
  fi
  if grep -q 'Reference already exists' "${err}"; then
    gh api --method PATCH "repos/${repo}/git/refs/heads/${branch}" -f "sha=${sha}" -F force=true > /dev/null
    return 0
  fi
  cat "${err}" >&2
  return 1
}

api_ref_delete() {
  local branch="$1" repo err
  branch_name_ok "${branch}" || die "refusing to delete branch ${branch}"
  repo="$(repo_slug)"
  err="$(mktemp)"
  if gh api --method DELETE "repos/${repo}/git/refs/heads/${branch}" > /dev/null 2> "${err}"; then return 0; fi
  if grep -q -E 'HTTP 422|HTTP 404|Reference does not exist' "${err}"; then return 0; fi
  cat "${err}" >&2
  return 1
}

api_branch_exists() {
  local branch="$1" repo err
  repo="$(repo_slug)"
  err="$(mktemp)"
  if gh api "repos/${repo}/git/ref/heads/${branch}" > /dev/null 2> "${err}"; then return 0; fi
  grep -q 'HTTP 404' "${err}" || { cat "${err}" >&2; die "could not look up branch ${branch}"; }
  return 1
}

# branch_tip_is_bot <branch> <title>: true when the branch tip is the sync bot's own commit
# for this title: signature verified, author the App, committer GitHub, the title as built,
# one parent (main) or two (main and a commit of upstream main). A human commit on top, or a
# different commit, is not. Sets BOT_TIP to the tip that was checked.
BOT_TIP=""
branch_tip_is_bot() {
  local branch="$1" title="$2" tip info repo np p2 rest
  repo="$(repo_slug)"
  tip="$(gh api "repos/${repo}/git/ref/heads/${branch}" --jq .object.sha)"
  info="$(gh api "repos/${repo}/git/commits/${tip}" --jq '[(.parents|length), (.parents[1].sha // ""), (.message|split("\n")[0]), (.author.name // ""), (.author.email // ""), (.committer.name // ""), (.committer.email // ""), (.verification.verified|tostring)]|@tsv')"
  BOT_TIP="${tip}"
  np="$(cut -f1 <<<"${info}")"
  p2="$(cut -f2 <<<"${info}")"
  rest="$(cut -f3- <<<"${info}")"
  [[ "${rest}" == "$(printf '%s\t%s\t%s\tGitHub\tnoreply@github.com\ttrue' "${title}" "${XS_BOT_LOGIN}" "${XS_BOT_EMAIL}")" ]] || return 1
  case "${np}" in
    1) return 0 ;;
    2) git merge-base --is-ancestor "${p2}" "origin/upstream/${XS_MAIN_BRANCH}" ;;
    *) return 1 ;;
  esac
}

# api_ref_set_if <branch> <sha> <expected-tip>: move the branch only when it still points at
# the tip that was checked (the ref API has no compare-and-swap, so the tip is read again
# right before the update; a push in that gap is not caught).
api_ref_set_if() {
  local branch="$1" sha="$2" expect="$3" cur
  cur="$(gh api "repos/$(repo_slug)/git/ref/heads/${branch}" --jq .object.sha)"
  [[ "${cur}" == "${expect}" ]] || return 1
  api_ref_set "${branch}" "${sha}"
}

# branch_guard <branch> <title>: refuse to overwrite a branch that exists and is not the
# bot's own sync commit.
branch_guard() {
  api_branch_exists "$1" || return 0
  branch_tip_is_bot "$1" "$2" ||
    die "$1 exists and is not a sync commit for this run; not overwriting it. Delete the branch if it is stale and re-run"
}

# xs_ns_path <path>: true when the path is in the xs namespace.
xs_ns_path() {
  local p="$1" rule
  for rule in "${XS_NS_PATHS[@]}"; do
    # shellcheck disable=SC2254 # the rule is a glob on purpose
    case "${p}" in ${rule}) return 0 ;; *) ;; esac
  done
  return 1
}

# xs_ns_paths <commit-ish>: NUL separated xs namespace paths in its tree. Fails when
# git cannot read the tree, so a git error never reads as "no such paths".
xs_ns_paths() {
  local list p
  list="$(mktemp)"
  if ! git ls-tree -r --name-only -z "$1" -- .github > "${list}"; then
    rm -f "${list}"
    return 1
  fi
  while IFS= read -r -d '' p; do
    if xs_ns_path "${p}"; then printf '%s\0' "${p}"; fi
  done < "${list}"
  rm -f "${list}"
}

# xs_ns_violations <upstream-commit> [<base-tree> <result-tree>]: one line per
# problem, nothing when clean. Upstream must not carry any path in the xs
# namespace; with the trees, the namespace must also be byte-identical between
# main and the sync result. Paths are shown with control characters replaced.
xs_ns_violations() {
  local up="$1" base="${2:-}" result="${3:-}" p list
  list="$(mktemp)"
  xs_ns_paths "${up}" > "${list}" || { rm -f "${list}"; return 1; }
  while IFS= read -r -d '' p; do
    printf 'upstream %s contains %s\n' "${up}" "${p//[[:cntrl:]]/?}"
  done < "${list}"
  if [[ -n "${base}" && -n "${result}" ]]; then
    git diff --no-renames --name-only -z "${base}" "${result}" -- .github > "${list}" || { rm -f "${list}"; return 1; }
    while IFS= read -r -d '' p; do
      if xs_ns_path "${p}"; then printf 'result differs from main at %s\n' "${p//[[:cntrl:]]/?}"; fi
    done < "${list}"
  fi
  rm -f "${list}"
}

# xs_neutralize: stdin to stdout with @, < and > made inert and backtick runs replaced.
xs_neutralize() {
  sed -e 's/@/@\xe2\x80\x8b/g' -e 's/</\xe2\x80\xb9/g' -e 's/>/\xe2\x80\xba/g' -e "s/\`\\+/'/g"
}

# xs_pr_state: stdin is `gh pr list --json number,state,isCrossRepository`. open|merged|closed <n>, or none.
xs_pr_state() {
  jq -r '[.[] | select(.isCrossRepository == false)] as $p
    | ($p | map(select(.state == "OPEN")) | first) as $o
    | ($p | map(select(.state == "MERGED")) | first) as $m
    | ($p | map(select(.state == "CLOSED")) | first) as $c
    | if $o then "open \($o.number)" elif $m then "merged \($m.number)" elif $c then "closed \($c.number)" else "none" end'
}

# xs_closed_upstream_pr <upstream-sha>: stdin is `gh pr list --state closed --json
# number,state,headRefName,isCrossRepository,author,body`. Prints the number of the
# newest PR that was closed without merging, has a sync/upstream-* head in this
# repository, was opened by the bot (XS_ISSUE_AUTHOR) and records that upstream tip
# in its body as the line "<!-- xs-sync:upstream <sha> -->". Empty when there is none.
# A closed PR is an explicit skip for that upstream tip, whatever day the next
# sync/upstream-<date> branch is named.
xs_closed_upstream_pr() {
  jq -r --arg a "${XS_ISSUE_AUTHOR}" --arg m "<!-- xs-sync:upstream $1 -->" \
    '[.[] | select(.isCrossRepository == false and .state == "CLOSED"
        and (.headRefName | startswith("sync/upstream-")) and .author.login == $a
        and ((.body // "") | split("\n") | map(rtrimstr("\r")) | index($m)))]
      | map(.number) | max // empty'
}

# closed_upstream_pr <upstream-sha>: see xs_closed_upstream_pr.
closed_upstream_pr() {
  [[ "$1" =~ ^[0-9a-f]{40}$ ]] || die "bad upstream sha $1"
  gh pr list --state closed --limit 100 --json number,state,headRefName,isCrossRepository,author,body | xs_closed_upstream_pr "$1"
}

# xs_workflows_to_disable: stdin is "id<TAB>path<TAB>state" lines (the Actions
# API). Prints "id<TAB>path" for every active workflow under .github/workflows/
# that is not ours. A workflow is ours when it is named xs-*.yml and none of the
# refs in XS_UPSTREAM_REFS (space separated: upstream main and the base tag)
# contains that path; an upstream file in our namespace stays disabled. Dynamic
# workflows (no such path) are left alone.
xs_workflows_to_disable() {
  local id path state ref theirs
  while IFS=$'\t' read -r id path state; do
    [[ "${state}" == active ]] || continue
    [[ "${path}" == .github/workflows/* ]] || continue
    if [[ "${path}" =~ ^\.github/workflows/xs-[A-Za-z0-9._-]+\.ya?ml$ ]]; then
      theirs=false
      for ref in ${XS_UPSTREAM_REFS:-}; do
        if git cat-file -e "${ref}:${path}" 2> /dev/null; then theirs=true; fi
      done
      [[ "${theirs}" == true ]] || continue
    fi
    printf '%s\t%s\n' "${id}" "${path}"
  done
}

# xs_github_changes <old> <new>: non-xs paths under .github that differ, as "<added|modified|deleted> <path>".
xs_github_changes() {
  local st p
  while IFS= read -r -d '' st && IFS= read -r -d '' p; do
    if xs_path_allowed "${p}"; then continue; fi
    case "${st}" in A) st=added ;; D) st=deleted ;; *) st=modified ;; esac
    printf '%s %s\n' "${st}" "${p}"
  done < <(git diff --no-renames --name-status -z "$1" "$2" -- .github)
}

# pr_state <head-branch>: the state of the PRs from this repository for that head.
pr_state() {
  gh pr list --state all --head "$1" --limit 20 --json number,state,isCrossRepository | xs_pr_state
}


# pr_find <head-branch> <open|all>: number of a PR from this repository with that
# head branch. PRs from forks are ignored: a fork can use any branch name.
pr_find() {
  gh pr list --state "$2" --head "$1" --limit 20 --json number,isCrossRepository \
    --jq '[.[] | select(.isCrossRepository == false)][0].number // empty'
}

# issue_find <exact-title> <label> [author]: number of the open issue with that
# title, our label and an author the bot owns (default the App; the failure issue
# is opened with GITHUB_TOKEN, so it passes XS_ISSUE_AUTHOR_ACTIONS). Anyone can
# open an issue on a public repo, so the title alone proves nothing.
issue_find() {
  [[ "$1" =~ ^[A-Za-z0-9\ ._:()/-]+$ ]] || die "bad issue title $1"
  [[ -n "${2:-}" ]] || die "issue_find needs a label"
  gh issue list --state open --author "${3:-${XS_ISSUE_AUTHOR}}" --label "$2" --search "\"$1\" in:title" --limit 30 --json number,title \
    --jq "map(select(.title == \"$1\")) | .[0].number // empty"
}

# issue_upsert <title> <label> <body-file>: create the issue or replace its body.
# Sets ISSUE_NUMBER. The search index lags behind new issues by a while, so an
# issue created seconds ago may be created again on a quick re-run; callers that
# need the number use ISSUE_NUMBER, not a search.
ISSUE_NUMBER=""
issue_upsert() {
  local title="$1" label="$2" body="$3" num url
  num="$(issue_find "${title}" "${label}")"
  if [[ -n "${num}" ]]; then
    gh issue edit "${num}" --body-file "${body}" > /dev/null
    echo "updated issue #${num}"
    ISSUE_NUMBER="${num}"
  else
    url="$(gh issue create --title "${title}" --label "${label}" --body-file "${body}")"
    echo "${url}"
    ISSUE_NUMBER="${url##*/}"
  fi
}

# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------

# apply_patch_index <patch-file> <index-file>
# Applies the patch to the tree already in the scratch index (3-way, no worktree).
# Returns 1 on conflict and prints the conflicting paths on fd 3.
apply_patch_index() {
  local patch="$1" index="$2" err rc=0
  err="$(mktemp)"
  GIT_INDEX_FILE="${index}" git apply --cached --3way "${patch}" 2> "${err}" || rc=$?
  if ((rc == 0)); then return 0; fi
  {
    GIT_INDEX_FILE="${index}" git ls-files -u -z | tr '\0' '\n' | cut -f2
    sed -n -E \
      -e 's/^error: patch failed: (.*):[0-9]+$/\1/p' \
      -e 's/^error: (.*): patch does not apply$/\1/p' \
      -e 's/^error: (.*): already exists in (working directory|index)$/\1/p' \
      -e 's/^error: (.*): does not exist in (working directory|index)$/\1/p' \
      -e 's/^Applied patch to .(.*). with conflicts\.$/\1/p' "${err}"
  } | LC_ALL=C sort -u >&3
  cat "${err}" >&2
  return 1
}

# non_chart_pathspec: git pathspec arguments that leave out our charts.
non_chart_pathspec() {
  local c
  printf '%s\0' .
  for c in "${XS_CHARTS[@]}"; do printf ':!charts/%s\0' "${c}"; done
}

# xs_patch_files <from-rev> <src-tree>: NUL separated paths of our patch set: the
# non-chart paths that differ from upstream main <from-rev>, then the chart paths
# that differ from each chart's tag (the tags are in the "chart:tag" arguments).
xs_patch_files() {
  local from="$1" src="$2" spec
  shift 2
  local -a ps=()
  mapfile -d '' ps < <(non_chart_pathspec)
  git diff --no-renames --name-only -z "${from}" "${src}" -- "${ps[@]}"
  for spec in "$@"; do
    git diff --no-renames --name-only -z "refs/tags/${spec#*:}" "${src}" -- "charts/${spec%%:*}"
  done
}

# index_rewrite <index> <path> <command...>: pipe the blob at <path> in the scratch
# index through the command and store the result.
index_rewrite() {
  local idx="$1" path="$2" mode blob
  shift 2
  mode="$(GIT_INDEX_FILE="${idx}" git ls-files -s -- "${path}" | cut -d' ' -f1)"
  [[ -n "${mode}" ]] || die "${path} is not in the tree being built"
  blob="$(GIT_INDEX_FILE="${idx}" git cat-file blob ":${path}" | "$@" | git hash-object -w --stdin)"
  GIT_INDEX_FILE="${idx}" git update-index --cacheinfo "${mode},${blob},${path}"
}

# chart_engine_tag <rev> <chart>: xscaler.engineTag default of the chart at <rev>.
chart_engine_tag() {
  git show "$1:charts/$2/${XS_ENGINE_TAG_FILE}" | sed -n -E 's/^[[:space:]]+engineTag: *["'"'"']?([^"'"'"'#[:space:]]+).*$/\1/p'
}

# chart_patch <chart> <from-tag> <src-tree> <out-file>: the chart patch, from the chart
# tag to the chart in <src-tree>, with the +xs.N build metadata taken off the chart
# version. The version and the engine tag are rewritten after the patch applies, so
# they must not be part of what the 3-way apply has to merge.
chart_patch() {
  local chart="$1" from="$2" src="$3" out="$4" idx tree blob mode
  idx="$(mktemp -u)"
  GIT_INDEX_FILE="${idx}" git read-tree "${src}"
  mode="$(GIT_INDEX_FILE="${idx}" git ls-files -s -- "charts/${chart}/Chart.yaml" | cut -d' ' -f1)"
  blob="$(git show "${src}:charts/${chart}/Chart.yaml" | sed -E 's/^(version: .*)\+xs\.[0-9]+[[:space:]]*$/\1/' | git hash-object -w --stdin)"
  GIT_INDEX_FILE="${idx}" git update-index --cacheinfo "${mode},${blob},charts/${chart}/Chart.yaml"
  tree="$(GIT_INDEX_FILE="${idx}" git write-tree)"
  rm -f "${idx}"
  git diff --no-renames --binary --full-index "refs/tags/${from}" "${tree}" -- "charts/${chart}" >> "${out}"
}

# chart_fixup <index> <chart> <old-app> <old-engine> <new-version> <new-app> <new-engine>
# Sets the chart version to <new-version> (<ver>+xs.<m>), the engine tag to <new-engine>, and
# moves the version numbers in the xs test files from the old chart to the new one.
chart_fixup() {
  local idx="$1" chart="$2" old_app="$3" old_engine="$4" new_ver="$5" new_app="$6" new_engine="$7" f
  index_rewrite "${idx}" "charts/${chart}/Chart.yaml" sed -E "s/^version: .*/version: ${new_ver}/"
  index_rewrite "${idx}" "charts/${chart}/${XS_ENGINE_TAG_FILE}" sed -E "s/^([[:space:]]+engineTag: ).*\$/\\1${new_engine}/"
  for f in "${XS_VERSION_TEST_FILES[@]}"; do
    if [[ -z "$(GIT_INDEX_FILE="${idx}" git ls-files -- "charts/${chart}/${f}")" ]]; then continue; fi
    OLD_APP="${old_app}" OLD_N="${old_engine##*-xs.}" NEW_APP="${new_app}" NEW_ENGINE="${new_engine}" \
      index_rewrite "${idx}" "charts/${chart}/${f}" perl -pe \
      's/(?<![0-9A-Za-z.])\Q$ENV{OLD_APP}\E(?:(-xs\.\Q$ENV{OLD_N}\E)(?![0-9])|(?![0-9A-Za-z-]))/$1 ? $ENV{NEW_ENGINE} : $ENV{NEW_APP}/ge'
  done
}

# assemble_tree <index> <upstream-rev> <upstream-base> <src-tree> <spec>...
# The one place the tree is built. Starts from upstream main <upstream-rev>, carries
# the xs files over from <src-tree> (relative to <upstream-base>, the upstream main
# <src-tree> is built on), and for each spec chart|from-tag|to-tag|to-engine|xs-n puts the
# chart at <to-tag> plus the chart patch taken from <from-tag> to <src-tree>. A spec
# with an empty to-tag keeps the chart as it is in <src-tree>. from-tag == to-tag is a
# rebuild of the same chart tag with a newer engine image (chart version +xs.<xs-n>). Prints the tree sha, or
# returns 1 with the conflicting paths on fd 3.
assemble_tree() {
  local idx="$1" up="$2" ub="$3" src="$4" spec chart from to engine
  shift 4
  local work patch ps
  work="$(mktemp -d)"
  patch="${work}/patch"
  : > "${patch}"
  GIT_INDEX_FILE="${idx}" git read-tree "${up}"
  mapfile -d '' ps < <(non_chart_pathspec)
  git diff --no-renames --binary --full-index "${ub}" "${src}" -- "${ps[@]}" >> "${patch}"
  local -a fixups=()
  for spec in "$@"; do
    IFS='|' read -r chart from to engine xsn <<<"${spec}"
    GIT_INDEX_FILE="${idx}" git rm -r -f -q --cached --ignore-unmatch -- "charts/${chart}"
    if [[ -z "${to}" ]]; then
      GIT_INDEX_FILE="${idx}" git read-tree --prefix="charts/${chart}/" "${src}:charts/${chart}"
      continue
    fi
    GIT_INDEX_FILE="${idx}" git read-tree --prefix="charts/${chart}/" "refs/tags/${to}:charts/${chart}"
    chart_patch "${chart}" "${from}" "${src}" "${patch}"
    fixups+=("${spec}")
  done
  if [[ -s "${patch}" ]]; then apply_patch_index "${patch}" "${idx}" || return 1; fi
  for spec in "${fixups[@]}"; do
    IFS='|' read -r chart from to engine xsn <<<"${spec}"
    local new_app
    new_app="$(chart_field "refs/tags/${to}" "${chart}" appVersion)"
    [[ "${engine}" =~ ^${new_app//./\\.}-xs\.(0|[1-9][0-9]*)$ ]] || die "engine tag ${engine} does not match appVersion ${new_app} of ${to}"
    chart_fixup "${idx}" "${chart}" "$(chart_field "${src}" "${chart}" appVersion)" "$(chart_engine_tag "${src}" "${chart}")" \
      "${to#"${chart}"-}+xs.${xsn:-0}" "${new_app}" "${engine}"
  done
  local tree
  tree="$(GIT_INDEX_FILE="${idx}" git write-tree)"
  for spec in "${fixups[@]}"; do
    IFS='|' read -r chart from to engine xsn <<<"${spec}"
    [[ "$(chart_field "${tree}" "${chart}" version)" == "${to#"${chart}"-}+xs.${xsn:-0}" ]] || die "${chart}: chart version is not ${to#"${chart}"-}+xs.${xsn:-0} after the build"
    [[ "$(chart_engine_tag "${tree}" "${chart}")" == "${engine}" ]] || die "${chart}: engine tag is not ${engine} after the build"
    [[ "$(git show "${tree}:charts/${chart}/${XS_ENGINE_TAG_FILE}" | grep -c -E '^[[:space:]]+engineTag: ')" == 1 ]] || die "${chart}: expected exactly one engineTag in ${XS_ENGINE_TAG_FILE}"
  done
  printf '%s\n' "${tree}"
}

cmd_build() {
  local base_commit="" base_tree="" up_commit="" up_base="" branch="" open_pr=true upstream_only=false
  local issue_title="" issue_label="sync-conflict"
  local -a bumps=()
  while (($#)); do
    case "$1" in
      --base-commit) base_commit="$2"; shift 2 ;;
      --base-tree) base_tree="$2"; shift 2 ;;
      --upstream-commit) up_commit="$2"; shift 2 ;;
      --upstream-base) up_base="$2"; shift 2 ;;
      --bump) bumps+=("$2"); shift 2 ;;
      --branch) branch="$2"; shift 2 ;;
      --no-pr) open_pr=false; shift ;;
      --upstream-only) upstream_only=true; shift ;;
      --issue-title) issue_title="$2"; shift 2 ;;
      --issue-label) issue_label="$2"; shift 2 ;;
      *) die "build: unknown option $1" ;;
    esac
  done
  local sha_re='^[0-9a-f]{40}$'
  [[ "${base_commit}" =~ ${sha_re} && "${base_tree}" =~ ${sha_re} && "${up_commit}" =~ ${sha_re} && "${up_base}" =~ ${sha_re} ]] ||
    die "--base-commit, --base-tree, --upstream-commit and --upstream-base must be full shas"
  ((${#bumps[@]} > 0 )) || [[ "${upstream_only}" == true ]] || die "build: no --bump given"
  ((${#bumps[@]} == 0)) || [[ "${upstream_only}" == false ]] || die "build: --upstream-only takes no --bump"

  # Per chart: bumped to the target, or kept as main has it.
  local chart c b cur bchart btag bengine
  local -a specs=() cmp=() targets=() cur_tags=() lines=()
  local -A bump_tag=() bump_engine=() bump_digest=()
  local bdigest
  for b in "${bumps[@]}"; do
    IFS=: read -r bchart btag bengine <<<"${b}"
    bdigest=""
    if [[ "${bengine}" == *@* ]]; then
      bdigest="${bengine#*@}"
      bengine="${bengine%%@*}"
      [[ "${bdigest}" =~ ^sha256:[0-9a-f]{64}$ ]] || die "bad --bump digest ${bdigest}"
    fi
    [[ -n "${XS_CHART_ENGINE[${bchart}]:-}" ]] || die "bad --bump chart ${bchart}"
    with_chart "${bchart}" xs_version_of "${btag}" > /dev/null || die "bad --bump tag ${btag}"
    [[ "${bengine}" =~ ^[0-9]+\.[0-9]+\.[0-9]+-xs\.(0|[1-9][0-9]*)$ ]] || die "bad --bump engine ${bengine}"
    git rev-parse --verify --quiet "refs/tags/${btag}^{commit}" > /dev/null || die "chart tag ${btag} is missing"
    bump_tag["${bchart}"]="${btag}"
    bump_engine["${bchart}"]="${bengine}"
    bump_digest["${bchart}"]="${bdigest}"
  done
  for chart in "${XS_CHARTS[@]}"; do
    cur="$(chart_current_tag "${base_tree}" "${chart}")"
    git rev-parse --verify --quiet "refs/tags/${cur}^{commit}" > /dev/null || die "chart tag ${cur} is missing"
    cmp+=("${chart}:${cur}")
    if [[ -n "${bump_tag[${chart}]:-}" && "${bump_tag[${chart}]}" == "${cur}" ]]; then
      # Rebuild: same chart tag, newer engine image, chart version +xs.<m+1>.
      local old_engine old_n new_n m
      old_engine="$(chart_engine_tag "${base_tree}" "${chart}")"
      old_n="${old_engine##*-xs.}"
      new_n="${bump_engine[${chart}]##*-xs.}"
      m="$(chart_field "${base_tree}" "${chart}" version)"
      m="${m##*+xs.}"
      [[ "${old_n}" =~ ^[0-9]+$ && "${m}" =~ ^[0-9]+$ ]] || die "${chart}: engineTag ${old_engine} or the chart version on main has no xs numbers"
      ((new_n > old_n)) || die "${chart}: engine ${bump_engine[${chart}]} is not newer than ${old_engine}"
      specs+=("${chart}|${cur}|${cur}|${bump_engine[${chart}]}|$((m + 1))")
      targets+=("${cur}-xs.$((m + 1))-e${new_n}")
      cur_tags+=("")
      lines+=("${chart}: ${cur} rebuilt as +xs.$((m + 1)) (engine ${old_engine} to ${bump_engine[${chart}]})")
    elif [[ -n "${bump_tag[${chart}]:-}" ]]; then
      xs_ver_gt "$(with_chart "${chart}" xs_version_of "${bump_tag[${chart}]}")" "$(with_chart "${chart}" xs_version_of "${cur}")" ||
        die "${bump_tag[${chart}]} is not newer than ${cur}"
      specs+=("${chart}|${cur}|${bump_tag[${chart}]}|${bump_engine[${chart}]}|0")
      targets+=("${bump_tag[${chart}]}")
      cur_tags+=("${cur}")
      lines+=("${chart}: ${cur} to ${bump_tag[${chart}]} (engine ${bump_engine[${chart}]})")
    else
      specs+=("${chart}|||")
    fi
  done
  local title
  if [[ "${upstream_only}" == true ]]; then
    title="chore(sync): sync upstream main ${up_commit:0:12}"
    : "${branch:=sync/upstream-${XS_TODAY:-$(date -u +%Y%m%d)}}"
  else
    title="chore(sync): sync charts to $(printf '%s\n' "${targets[@]}" | paste -sd, - | sed 's/,/, /g')"
    : "${branch:=$(xs_head "${targets[@]}")}"
  fi
  : "${issue_title:=sync: ${branch#*/} conflicts}"
  branch_name_ok "${branch}" || die "bad branch ${branch}"

  # A sync PR that was closed without merging is an explicit skip; a merged one whose
  # content main does not have means something unusual happened.
  local pr_st="none"
  if [[ "${open_pr}" == true ]]; then
    pr_st="$(pr_state "${branch}")"
    case "${pr_st}" in
      "closed "*)
        echo "skipped by closed PR #${pr_st#closed }"
        summary "### build-sync: skipped by closed PR #${pr_st#closed } (${branch}). Reopen it, or delete the branch to let the sync rebuild."
        out result skipped
        return 0
        ;;
      "merged "*) die "${branch} has merged PR #${pr_st#merged }, but main does not hold its content. Merge sync PRs with a merge commit" ;;
    esac
    # An upstream refresh closed without merging is skipped for that upstream tip, not
    # just for the day: tomorrow's sync/upstream-<date> branch has a new name.
    if [[ "${upstream_only}" == true && "${pr_st}" != "open "* ]]; then
      local closed_pr
      closed_pr="$(closed_upstream_pr "${up_commit}")"
      if [[ -n "${closed_pr}" ]]; then
        echo "skipped by closed PR #${closed_pr}"
        summary "### build-sync: skipped by closed PR #${closed_pr} (upstream main ${up_commit}). Reopen it, or wait for upstream to move."
        out result skipped
        return 0
      fi
    fi
  fi

  local work index files_file nfiles up_tree
  work="$(mktemp -d)"
  index="${work}/index"
  files_file="${work}/files"
  up_tree="$(git rev-parse "${up_commit}^{tree}")"
  # Upstream never owns our namespace: a commit that carries an xs-* workflow, script
  # or action would land on main as one of ours.
  local ns
  ns="$(xs_ns_violations "${up_commit}")" || die "cannot list the xs namespace of ${up_commit}"
  [[ -z "${ns}" ]] || die "upstream main ${up_commit} holds paths in the xs namespace, which only this fork may own: $(head -n 20 <<<"${ns}" | tr '\n' ';')"
  xs_patch_files "${up_base}" "${base_tree}" "${cmp[@]}" > "${files_file}"
  nfiles="$(tr -cd '\0' < "${files_file}" | wc -c)"
  echo "patch: ${nfiles} file(s)"

  local conflicts="${work}/conflicts" tree
  if ! tree="$(assemble_tree "${index}" "${up_commit}" "${up_base}" "${base_tree}" "${specs[@]}" 3> "${conflicts}")"; then
    log "patch does not apply"
    local body="${work}/issue.md"
    {
      echo "The xScaler patch set does not apply to ${targets[*]}."
      echo
      echo "Base: ${base_commit}, upstream main ${up_commit}"
      echo
      echo "Conflicting files:"
      if [[ -s "${conflicts}" ]]; then
        tr '\n' '\0' < "${conflicts}" | xs_md_paths
      else
        echo "- (not reported by git apply, see the run log)"
      fi
      echo
      echo "Reproduce, per chart (the chart patch is the diff from the current chart tag to origin/${XS_MAIN_BRANCH}):"
      echo
      echo '```sh'
      echo "git fetch origin 'refs/tags/*:refs/tags/*' ${XS_MAIN_BRANCH}"
      for b in "${!bump_tag[@]}"; do
        echo "git switch --detach ${bump_tag[${b}]}"
        printf '%s\n' "git diff --no-renames refs/tags/${b}-<current ${b} version> origin/${XS_MAIN_BRANCH} --binary --full-index -- charts/${b} | git apply --3way"
      done
      echo '```'
      echo
      echo "Resolve the conflicts on a branch, open a PR into ${XS_MAIN_BRANCH} that merges upstream main, and keep"
      echo "every path outside our patch set byte-identical to upstream main and to the chart tag."
    } > "${body}"
    ensure_label "${issue_label}" B60205 "xs-sync could not apply the patch set to a new upstream release"
    issue_upsert "${issue_title}" "${issue_label}" "${body}"
    summary "### build-sync: conflict"
    summary "Patch set does not apply to ${targets[*]}. Issue \"${issue_title}\" opened or updated."
    out result conflict
    out issue "${ISSUE_NUMBER}"
    return 0
  fi
  echo "result tree ${tree}"
  ns="$(xs_ns_violations "${up_commit}" "${base_tree}" "${tree}")" || die "cannot compare the xs namespace of main and the result"
  [[ -z "${ns}" ]] || die "the sync result changes the xs namespace of ${XS_MAIN_BRANCH}: $(head -n 20 <<<"${ns}" | tr '\n' ';')"

  local -a parents=("${base_commit}")
  if [[ "${up_commit}" != "${up_base}" ]]; then parents+=("${up_commit}"); fi

  local msg="${work}/message" l
  {
    echo "${title}"
    echo
    echo "main is on upstream main ${up_base} with the xScaler patch set. Move the"
    echo "charts that have a newer upstream release with a released engine image:"
    for l in "${lines[@]}"; do echo "- ${l}"; done
    echo
    echo "The tree is upstream main ${up_commit} with each chart at the new tag plus the"
    echo "chart patch. Chart versions read <version>+xs.0, xscaler.engineTag the engine tag."
    echo
    echo "Release tags: https://github.com/${XS_UPSTREAM_REPO}/tags"
    echo
    echo "Patch files (${nfiles}):"
    xs_md_paths plain < "${files_file}"
  } > "${msg}"

  if [[ "${open_pr}" == true ]]; then
    if [[ "${pr_st}" == "open "* ]]; then
      # An open bot PR: refresh it when main moved, only while the branch is still the
      # bot's own commit.
      local num="${pr_st#open }" tip p1 repo
      repo="$(repo_slug)"
      tip="$(gh api "repos/${repo}/git/ref/heads/${branch}" --jq .object.sha)"
      p1="$(gh api "repos/${repo}/git/commits/${tip}" --jq '.parents[0].sha')"
      out pr "${num}"
      if [[ "${p1}" == "${base_commit}" ]]; then
        echo "PR #${num} is open and up to date"
        out result exists
        return 0
      fi
      local refreshed=""
      if branch_tip_is_bot "${branch}" "${title}"; then
        refreshed="$(api_commit "${up_tree}" "${tree}" "${msg}" "${parents[@]}")"
        if api_ref_set_if "${branch}" "${refreshed}" "${BOT_TIP}"; then
          echo "refreshed PR #${num}: ${branch} -> ${refreshed}"
          summary "### build-sync: refreshed PR #${num} onto ${base_commit}"
          out result refreshed
          out commit "${refreshed}"
          return 0
        fi
        refreshed=""
      fi
      if [[ -z "${refreshed}" ]]; then
        local marked
        marked="$(gh pr view "${num}" --json comments --jq '[.comments[].body | select(contains("xs-sync:needs-manual"))] | length')"
        if [[ "${marked}" == 0 ]]; then
          gh pr comment "${num}" --body "main moved since this PR was built, and ${branch} is not the sync bot's own commit any more (or changed while it was refreshed), so it cannot be refreshed automatically. Merge ${XS_MAIN_BRANCH} into the branch, or close this PR and delete the branch so the sync rebuilds it.
<!-- xs-sync:needs-manual -->" > /dev/null
        fi
        summary "### build-sync: PR #${num} needs a manual update (main moved, branch has other commits)"
        out result needs-manual
      fi
      return 0
    fi
    branch_guard "${branch}" "${title}"
  fi

  local commit
  commit="$(api_commit "${up_tree}" "${tree}" "${msg}" "${parents[@]}")"
  api_ref_set "${branch}" "${commit}"
  local verified
  verified="$(gh api "repos/$(repo_slug)/git/commits/${commit}" --jq '.verification.verified')"
  echo "branch ${branch} -> ${commit} (verified: ${verified})"
  out result created
  out branch "${branch}"
  out commit "${commit}"
  out tree "${tree}"
  out parents "$(IFS=,; echo "${parents[*]}")"
  out verified "${verified}"
  summary "### build-sync"
  summary "Branch \`${branch}\` at \`${commit}\`, tree \`${tree}\`, signature verified: ${verified}."

  if [[ "${open_pr}" == true ]]; then
    # A conflict issue for this head is resolved now.
    local old
    old="$(issue_find "${issue_title}" "${issue_label}" || true)"
    if [[ -n "${old}" ]]; then
      gh issue close "${old}" --comment "The patch set applies now; sync PR follows." > /dev/null
    fi
    local pr_body="${work}/pr.md" i
    {
      if [[ "${upstream_only}" == true ]]; then
        echo "Upstream refresh: the charts stay as they are, the rest of the repository moves to upstream main."
        echo "<!-- xs-sync:upstream ${up_commit} -->"
      else
        echo "Chart changes (a chart is bumped or rebuilt only when its engine image ${XS_ENGINE_REGISTRY}/${XS_ENGINE_ORG}/<engine>:<appVersion>-xs.N is released, signed and attested by the engine release workflow):"
        echo
        for l in "${lines[@]}"; do echo "- ${l}"; done
        echo
        echo "Verified engine digests (the tag in values.yaml must still resolve to them; xs-sync-check verifies this):"
        echo
        for chart in "${!bump_digest[@]}"; do
          [[ -z "${bump_digest[${chart}]}" ]] || echo "- ${chart}: \`${bump_engine[${chart}]}\` is \`${bump_digest[${chart}]}\`"
        done
        for chart in "${!bump_digest[@]}"; do
          [[ -z "${bump_digest[${chart}]}" ]] || echo "<!-- xs-sync:engine ${chart} ${bump_digest[${chart}]} -->"
        done
        echo
      fi
      for ((i = 0; i < ${#targets[@]}; i++)); do
        if [[ -n "${cur_tags[i]}" ]]; then echo "Upstream changes: https://github.com/${XS_UPSTREAM_REPO}/compare/${cur_tags[i]}...${targets[i]}"; fi
      done
      echo
      echo "The rest of the repository is upstream main ${up_commit}. The commit has main"
      echo "as its first parent and, when upstream main moved, upstream main as its second."
      echo
      echo "Merge this PR with a merge commit. A squash or rebase drops the upstream main parent from"
      echo "main's history, and the next sync derives the upstream base from it."
      echo
      echo "### Patch files (${nfiles})"
      echo
      xs_md_paths < "${files_file}"
      echo
      local gh_changes="${work}/gh-changes" ngh
      xs_github_changes "${up_base}" "${up_commit}" > "${gh_changes}"
      ngh="$(wc -l < "${gh_changes}")"
      echo "### Upstream changes under .github (${ngh})"
      echo
      if ((ngh > 0)); then
        echo "Upstream workflows and scripts that changed between upstream main ${up_base} and ${up_commit}."
        echo "Upstream workflows stay disabled: xs-sync disables any that are not ours on its next run."
        echo
        echo '```'
        awk 'NR <= 200' "${gh_changes}" | xs_neutralize
        echo '```'
      else
        echo "None."
      fi
    } > "${pr_body}"
    local url
    url="$(gh pr create --base "${XS_MAIN_BRANCH}" --head "${branch}" --title "${title}" --body-file "${pr_body}")"
    echo "opened ${url}"
    out pr "${url}"
    summary "Opened ${url}"
  fi
}

# ---------------------------------------------------------------------------
# disable-upstream-workflows
# ---------------------------------------------------------------------------
cmd_disable_workflows() {
  local repo id path failed=0 base ref
  repo="$(repo_slug)"
  # Upstream refs that decide whether an xs-* workflow is ours: upstream main and the
  # upstream commit main is based on. A missing ref stops the job: guessing would
  # either disable our workflows or leave an upstream one active.
  git rev-parse --verify --quiet "origin/upstream/main^{commit}" > /dev/null || die "origin/upstream/main is missing; fetch the full history"
  base="$(git merge-base HEAD origin/upstream/main)" || die "HEAD and origin/upstream/main share no history"
  XS_UPSTREAM_REFS="origin/upstream/main ${base}"
  for ref in ${XS_UPSTREAM_REFS}; do
    git rev-parse --verify --quiet "${ref}^{commit}" > /dev/null || die "${ref} is missing; fetch the full history"
  done
  export XS_UPSTREAM_REFS
  while IFS=$'\t' read -r id path; do
    if gh api --method PUT "repos/${repo}/actions/workflows/${id}/disable" > /dev/null; then
      echo "disabled ${path} (${id})"
    else
      echo "::warning::could not disable ${path} (${id})"
      failed=$((failed + 1))
    fi
  done < <(gh api --paginate "repos/${repo}/actions/workflows?per_page=100" --jq '.workflows[] | [.id, .path, .state] | @tsv' | xs_workflows_to_disable)
  ((failed == 0)) || die "${failed} upstream workflow(s) could not be disabled"
}

# ---------------------------------------------------------------------------
# supersede
# ---------------------------------------------------------------------------
cmd_supersede() {
  local latest="$1" head num
  shift
  for head in "$@"; do
    if ! xs_bot_head "${head}"; then
      echo "::warning::skipping ${head}: not a head this sync creates"
      continue
    fi
    num="$(pr_find "${head}" open)"
    if [[ -n "${num}" ]]; then
      gh pr close "${num}" --comment "superseded by ${latest}" > /dev/null
      echo "closed PR #${num} (${head})"
      api_ref_delete "${head}"
    else
      echo "::warning::${head} has no open PR from this repository; its branch is left alone"
    fi
    num="$(issue_find "sync: ${head#sync/} conflicts" sync-conflict || true)"
    if [[ -n "${num}" ]]; then gh issue close "${num}" --comment "superseded by ${latest}" > /dev/null; fi
  done
}

# ---------------------------------------------------------------------------
# rehearse: detect + build against an artificial base, nothing touches main
#
# Targets are the chart tags this checkout is on (Chart.yaml of HEAD). The base is an
# older chart tag per chart (the previous stable one; for merge and conflict the first
# older tag that has a suitable file) plus our patch set, written to a dangling commit.
# The engine lookup is mocked ("released") for the targets only; no engine image is
# needed. The patch set is the difference between the chart tags and HEAD.
#   clean      the build must reproduce HEAD exactly (both charts bumped)
#   upstream   the base is also an older upstream main commit, so the rest of the
#              repository has to be brought forward too; the result is still HEAD
#   merge      the base also edits an upstream chart file the target edits elsewhere;
#              the result must be HEAD plus that edit (a real 3-way apply)
#   conflict   the base rewrites a file the target changed; no branch, an issue
#   nothing    no engine is released: detect finds nothing to do and nothing is built
#   drift      no chart moves but main's upstream base is behind: an upstream-only refresh
#              (--upstream-only, thresholds forced to 0) that reproduces HEAD
#   rebuild    main is the base and a newer engine build (-xs.1) of the same appVersion is
#              released: the charts keep their tags and become +xs.1 with the new engine
#              tag (the expected tree is made with plain sed, not by the build)
# Branch and issue names carry the run id so concurrent rehearsals never share state.
# ---------------------------------------------------------------------------
REHEARSAL_BRANCH=""
REHEARSAL_TITLE=""
REHEARSAL_ISSUE=""
rehearsal_cleanup() {
  local n="${REHEARSAL_ISSUE}"
  if [[ -n "${REHEARSAL_BRANCH}" ]]; then api_ref_delete "${REHEARSAL_BRANCH}" || true; fi
  if [[ -z "${n}" && -n "${REHEARSAL_TITLE}" ]]; then n="$(issue_find "${REHEARSAL_TITLE}" rehearsal || true)"; fi
  if [[ -n "${n}" ]]; then gh issue close "${n}" --comment "rehearsal finished" > /dev/null || true; fi
}

# rehearsal_file <chart> <base-tag> <target-tag> <expect-rev> <min-first-hunk>: a text
# file of the chart that the target changes, that our patch does not touch, with its
# first changed line at least <min-first-hunk> lines down (0 = any).
rehearsal_file() {
  local chart="$1" base="$2" target="$3" expect="$4" min="$5" f first hunks
  while IFS= read -r -d '' f; do
    git cat-file -e "refs/tags/${base}:${f}" 2> /dev/null || continue
    git diff --quiet "refs/tags/${target}" "${expect}" -- "${f}" || continue
    if git diff --numstat "refs/tags/${base}" "refs/tags/${target}" -- "${f}" | grep -q '^-'; then continue; fi
    [[ "$(git ls-tree "refs/tags/${base}" -- "${f}" | cut -d' ' -f1)" == 100644 ]] || continue
    if ((min > 0)); then
      hunks="$(git diff -U0 "refs/tags/${base}" "refs/tags/${target}" -- "${f}" | sed -n -E 's/^@@ -([0-9]+)(,[0-9]+)? .*/\1/p')"
      first="${hunks%%$'\n'*}"
      if [[ -z "${first}" ]] || ((first < min)); then continue; fi
    fi
    printf '%s\n' "${f}"
    return 0
  done < <(git diff --no-renames --name-only -z --diff-filter=M "refs/tags/${base}" "refs/tags/${target}" -- "charts/${chart}" ":!charts/${chart}/Chart.yaml")
  return 1
}

# older_tags <chart> <tag>: stable chart tags below <tag>, newest first.
older_tags() {
  local chart="$1" tv v t
  tv="$(with_chart "${chart}" xs_version_of "$2")" || die "$2 is not a stable ${chart} chart tag"
  while read -r v t; do
    if xs_ver_gt "${tv}" "${v}"; then echo "${t}"; fi
  done < <(git tag --list "${chart}-*" | with_chart "${chart}" xs_sorted_stable) | tac
}

# rehearsal_variant <tree> <chart> <m> <n>: the tree with the chart set to version
# <ver>+xs.<m> and engine tag <appVersion>-xs.<n> (version numbers in the xs test files
# follow). Plain sed, independent of the build, so the rehearsal does not check the
# build against itself.
rehearsal_variant() {
  local tree="$1" chart="$2" m="$3" n="$4" idx old app ver new f
  idx="$(mktemp -u)"
  GIT_INDEX_FILE="${idx}" git read-tree "${tree}"
  old="$(chart_engine_tag "${tree}" "${chart}")"
  app="$(chart_field "${tree}" "${chart}" appVersion)"
  ver="$(chart_field "${tree}" "${chart}" version)"
  ver="${ver%%+*}"
  new="${app}-xs.${n}"
  index_rewrite "${idx}" "charts/${chart}/Chart.yaml" sed -E "s/^version: .*/version: ${ver}+xs.${m}/"
  index_rewrite "${idx}" "charts/${chart}/${XS_ENGINE_TAG_FILE}" sed -E "s/^([[:space:]]+engineTag: ).*\$/\\1${new}/"
  for f in "${XS_VERSION_TEST_FILES[@]}"; do
    if [[ -z "$(GIT_INDEX_FILE="${idx}" git ls-files -- "charts/${chart}/${f}")" ]]; then continue; fi
    index_rewrite "${idx}" "charts/${chart}/${f}" sed "s/${old//./\\.}/${new}/g"
  done
  GIT_INDEX_FILE="${idx}" git write-tree
  rm -f "${idx}"
}

cmd_rehearse() {
  local kind="${1:?rehearse clean|upstream|merge|conflict|nothing|rebuild|drift}"
  [[ "${kind}" == clean || "${kind}" == upstream || "${kind}" == merge || "${kind}" == conflict || "${kind}" == nothing || "${kind}" == rebuild || "${kind}" == drift ]] || die "unknown rehearsal ${kind}"
  export XS_MOCK_OK=1
  local expect_ref="${XS_REHEARSAL_EXPECT:-HEAD}" up_ref="${XS_REHEARSAL_UPSTREAM:-origin/upstream/main}" rid="${GITHUB_RUN_ID:-local$$}"
  local expect_tree m up_base chart
  expect_tree="$(git rev-parse "${expect_ref}^{tree}")"
  m="$(git merge-base "${expect_ref}" "${up_ref}")" || die "${expect_ref} and ${up_ref} share no history"
  up_base="${m}"
  # The build always writes +xs.0 and the engine N it is given; start from a tree on +xs.0 / -xs.0.
  for chart in "${XS_CHARTS[@]}"; do expect_tree="$(rehearsal_variant "${expect_tree}" "${chart}" 0 0)"; done

  # Targets and bases per chart.
  local -A target=() base=() tapp=()
  local -a specs=() caps=() mocks=() targets=() head_targets=()
  local mockn=0
  if [[ "${kind}" == rebuild ]]; then mockn=1; fi
  local t b first=""
  for chart in "${XS_CHARTS[@]}"; do
    t="$(chart_current_tag "${expect_ref}" "${chart}")"
    target["${chart}"]="${t}"
    tapp["${chart}"]="$(xs_chart_app "${chart}" "${t}")"
    targets+=("${t}")
    caps+=(--cap "${t}")
    mocks+=("${XS_CHART_ENGINE[${chart}]}:${tapp[${chart}]}:${mockn}")
    if [[ "${kind}" == rebuild ]]; then head_targets+=("${t}-xs.1-e1"); else head_targets+=("${t}"); fi
    [[ -n "${first}" ]] || first="${chart}"
  done
  local f=""
  for chart in "${XS_CHARTS[@]}"; do
    local min=0 walk=false
    if [[ "${kind}" == merge ]]; then min=10; fi
    if [[ "${chart}" == "${first}" && ( "${kind}" == merge || "${kind}" == conflict ) ]]; then walk=true; fi
    local found="" n=0
    if [[ "${kind}" == rebuild || "${kind}" == drift ]]; then
      base["${chart}"]="${target[${chart}]}"
      echo "rehearsal ${kind}: ${chart} stays on ${target[${chart}]}"
      if [[ "${kind}" == drift ]]; then specs+=("${chart}|||"); fi
      continue
    fi
    while read -r b; do
      n=$((n + 1))
      ((n <= 40)) || break
      if [[ "${walk}" == true ]]; then
        f="$(rehearsal_file "${chart}" "${b}" "${target[${chart}]}" "${expect_ref}" "${min}" || true)"
        [[ -n "${f}" ]] || continue
      fi
      found="${b}"
      break
    done < <(older_tags "${chart}" "${target[${chart}]}")
    [[ -n "${found}" ]] || die "${chart}: no older stable chart tag for the ${kind} rehearsal"
    base["${chart}"]="${found}"
    specs+=("${chart}|${target[${chart}]}|${found}|$(xs_chart_app "${chart}" "${found}")-xs.0")
    echo "rehearsal ${kind}: ${chart} base ${found}, target ${target[${chart}]}"
  done

  # An older upstream main commit for the upstream rehearsal: the newest ancestor
  # of the upstream commit that differs from it outside our charts.
  local ub_art="${m}" c
  if [[ "${kind}" == upstream || "${kind}" == drift ]]; then
    local -a ps=()
    mapfile -d '' ps < <(non_chart_pathspec)
    ub_art=""
    while read -r c; do
      if ! git diff --quiet "${c}" "${m}" -- "${ps[@]}"; then ub_art="${c}"; break; fi
    done < <(git rev-list --first-parent -n 300 "${m}~1")
    [[ -n "${ub_art}" ]] || die "no older upstream main commit differs from ${m} outside the charts"
    echo "rehearsal upstream: base is upstream main ${ub_art}, target ${m}"
  fi

  local work index synth_tree synth_local base_remote
  work="$(mktemp -d)"
  index="${work}/index"
  if [[ "${kind}" == rebuild ]]; then
    # main itself is the base; the expected result is main with the newer engine.
    synth_tree="${expect_tree}"
    for chart in "${XS_CHARTS[@]}"; do expect_tree="$(rehearsal_variant "${expect_tree}" "${chart}" 1 1)"; done
  else
    synth_tree="$(assemble_tree "${index}" "${ub_art}" "${m}" "${expect_tree}" "${specs[@]}" 3>&2)" || die "patch set does not apply to the base chart tags"
  fi

  local branch="rehearsal-sync/${head_targets[0]:-${targets[0]}}-${kind}-${rid}"
  local issue_title="rehearsal sync: ${kind} ${rid} conflicts"
  if [[ "${kind}" == conflict ]]; then
    local cf="${first}" blob
    f="$(rehearsal_file "${cf}" "${base[${cf}]}" "${target[${cf}]}" "${expect_ref}" 0)" || die "no text file changed between ${base[${cf}]} and ${target[${cf}]}"
    echo "conflict file: ${f}"
    blob="$(printf 'xs rehearsal conflict\n' | git hash-object -w --stdin)"
    GIT_INDEX_FILE="${index}" git update-index --cacheinfo "100644,${blob},${f}"
    synth_tree="$(GIT_INDEX_FILE="${index}" git write-tree)"
  elif [[ "${kind}" == merge ]]; then
    local mf="${first}" line='xs rehearsal merge line' bblob eblob eindex="${work}/expect-index"
    f="$(rehearsal_file "${mf}" "${base[${mf}]}" "${target[${mf}]}" "${expect_ref}" 10)" || die "no file changed between ${base[${mf}]} and ${target[${mf}]} away from its first lines"
    echo "merge file: ${f}"
    bblob="$({ echo "${line}"; git cat-file blob "refs/tags/${base[${mf}]}:${f}"; } | git hash-object -w --stdin)"
    GIT_INDEX_FILE="${index}" git update-index --cacheinfo "100644,${bblob},${f}"
    synth_tree="$(GIT_INDEX_FILE="${index}" git write-tree)"
    eblob="$({ echo "${line}"; git cat-file blob "${expect_ref}:${f}"; } | git hash-object -w --stdin)"
    GIT_INDEX_FILE="${eindex}" git read-tree "${expect_ref}"
    GIT_INDEX_FILE="${eindex}" git update-index --cacheinfo "100644,${eblob},${f}"
    expect_tree="$(GIT_INDEX_FILE="${eindex}" git write-tree)"
  fi
  synth_local="$(git -c user.name=xs-sync -c user.email=xs-sync@localhost commit-tree "${synth_tree}" -p "${ub_art}" -m "rehearsal base")"

  # Detect must see the artificial base on the base chart tags.
  local det k v bumpstr=""
  det="$(XS_DRIFT_COMMITS="$(if [[ "${kind}" == drift ]]; then echo 0; else echo "${XS_DRIFT_COMMITS}"; fi)" \
    XS_ENGINE_MOCK="$(if [[ "${kind}" == nothing || "${kind}" == drift ]]; then :; else echo "${mocks[*]}"; fi)" \
    cmd_detect --base "${synth_local}" --upstream "${m}" "${caps[@]}")"
  echo "${det}"
  while IFS='=' read -r k v; do [[ "${k}" == bumps ]] && bumpstr="${v}"; done <<<"${det}"
  if [[ "${kind}" == nothing ]]; then
    grep -qx 'proceed=false' <<<"${det}" || die "rehearsal: detect proceeded with no released engine"
    [[ -z "${bumpstr}" ]] || die "rehearsal: detect found bumps (${bumpstr}) with no released engine"
    echo "rehearsal nothing OK: no engine released, nothing to build"
    summary "### rehearsal nothing: OK (no released engine, no bump, no PR)"
    return 0
  fi
  grep -qx 'proceed=true' <<<"${det}" || die "detect did not proceed"
  local -a bump_args=()
  local want="" x
  if [[ "${kind}" == drift ]]; then
    [[ -z "${bumpstr}" ]] || die "rehearsal: drift detect found bumps (${bumpstr})"
    grep -qx 'drift=true' <<<"${det}" || die "rehearsal: detect did not report drift"
    grep -qE '^head=sync/upstream-[0-9]{8}$' <<<"${det}" || die "rehearsal: detect head is not sync/upstream-<date>"
    bump_args=(--upstream-only)
    want="${bumpstr}"
  fi
  for chart in "${XS_CHARTS[@]}"; do [[ "${kind}" == drift ]] && break; want+="${want:+ }${chart}:${target[${chart}]}:${tapp[${chart}]}-xs.${mockn}@sha256:$(printf '%064d' 0)"; done
  [[ "${bumpstr}" == "${want}" ]] || die "detect bumps '${bumpstr}' != '${want}'"
  for x in ${bumpstr}; do bump_args+=(--bump "${x}"); done
  if [[ "${kind}" != drift ]]; then
    grep -qx "head=$(xs_head "${head_targets[@]}")" <<<"${det}" || die "detect head is not $(xs_head "${head_targets[@]}")"
  fi

  # The artificial base on the remote (dangling, only used as a parent).
  printf 'rehearsal base: upstream main %s, charts at older tags plus patch set\n' "${ub_art}" > "${work}/base-msg"
  base_remote="$(api_commit "$(git rev-parse "${ub_art}^{tree}")" "${synth_tree}" "${work}/base-msg" "${ub_art}")"
  echo "artificial base ${base_remote}"

  REHEARSAL_BRANCH="${branch}"
  REHEARSAL_TITLE="${issue_title}"
  trap rehearsal_cleanup EXIT

  local res
  res="$(cmd_build --base-commit "${base_remote}" --base-tree "${synth_tree}" --upstream-commit "${m}" --upstream-base "${ub_art}" \
    "${bump_args[@]}" --branch "${branch}" --no-pr --issue-title "${issue_title}" --issue-label rehearsal)"
  echo "${res}"
  if [[ "${kind}" == clean || "${kind}" == upstream || "${kind}" == merge || "${kind}" == rebuild || "${kind}" == drift ]]; then
    grep -qx 'result=created' <<<"${res}" || die "rehearsal: expected a created branch"
    local got commit remote_tree parents want_parents
    got="$(grep '^tree=' <<<"${res}" | cut -d= -f2)"
    commit="$(grep '^commit=' <<<"${res}" | cut -d= -f2)"
    [[ "${got}" == "${expect_tree}" ]] || die "rehearsal tree ${got} != expected ${expect_tree}"
    remote_tree="$(gh api "repos/$(repo_slug)/git/commits/${commit}" --jq .tree.sha)"
    [[ "${remote_tree}" == "${expect_tree}" ]] || die "remote tree ${remote_tree} != expected ${expect_tree}"
    parents="$(gh api "repos/$(repo_slug)/git/commits/${commit}" --jq '[.parents[].sha]|join(",")')"
    want_parents="${base_remote}"
    if [[ "${m}" != "${ub_art}" ]]; then want_parents="${base_remote},${m}"; fi
    [[ "${parents}" == "${want_parents}" ]] || die "unexpected parents ${parents}, want ${want_parents}"
    echo "rehearsal ${kind} OK: tree ${got}, parents ${parents}"
    summary "### rehearsal ${kind}: OK (${bumpstr}, tree ${got}, verified $(grep '^verified=' <<<"${res}" | cut -d= -f2))"
  else
    grep -qx 'result=conflict' <<<"${res}" || die "rehearsal: expected a conflict"
    if api_branch_exists "${branch}"; then die "rehearsal: branch ${branch} exists after a conflict"; fi
    REHEARSAL_ISSUE="$(grep '^issue=' <<<"${res}" | cut -d= -f2)"
    [[ -n "${REHEARSAL_ISSUE}" ]] || die "rehearsal: no conflict issue number reported"
    [[ "$(gh issue view "${REHEARSAL_ISSUE}" --json title,state --jq '.title + "|" + .state')" == "${issue_title}|OPEN" ]] ||
      die "rehearsal: issue #${REHEARSAL_ISSUE} is not the open conflict issue"
    echo "rehearsal conflict OK: issue created, no branch"
    summary "### rehearsal conflict: OK (${bumpstr}, issue created and closed, no branch)"
  fi
}

# ---------------------------------------------------------------------------
# check (pull request validation for sync/* heads)
#   identity  outside our charts and the xs files the tree equals the upstream main
#             commit the sync used; each of our charts equals its chart tag except
#             our chart patch paths
#   parents   first parent is on main, the optional second is upstream main
#   charts    Chart.yaml, appVersion and engineTag agree, and the engine image is
#             released (cosign verified)
# ---------------------------------------------------------------------------
# head_upstream <head>: the upstream main commit a sync commit was built on.
head_upstream() {
  local head="$1" n
  n="$(git rev-list --parents -n 1 "${head}" | wc -w)"
  case "${n}" in
    3) git rev-parse "${head}^2" ;;
    2) git merge-base "${head}^1" "origin/upstream/main" ;;
    *) die "${head} is not a sync commit (it has $((n - 1)) parents)" ;;
  esac
}

cmd_check() {
  local what="${1:?check identity|parents|charts}" head="${2:-HEAD}" body_file="${3:-}"
  local base_ref="origin/${XS_MAIN_BRANCH}" up chart cur tag n p bad
  case "${what}" in
    identity)
      up="$(head_upstream "${head}")"
      bad=0
      n=0
      # Upstream must not own our namespace: the upstream commit this head is built
      # on holds no xs-* workflow, script or action.
      local ns line
      ns="$(xs_ns_violations "${up}")" || die "cannot list the xs namespace of ${up}"
      while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        echo "::error::${line}"
        bad=$((bad + 1))
      done <<<"${ns}"
      local -a ps=()
      mapfile -d '' ps < <(non_chart_pathspec)
      while IFS= read -r -d '' p; do
        n=$((n + 1))
        if ! xs_path_allowed "${p}"; then
          echo "::error::${p} differs from upstream main ${up} and is not a patch path"
          bad=$((bad + 1))
        fi
      done < <(git diff --no-renames --name-only -z "${up}" "${head}" -- "${ps[@]}")
      for chart in "${XS_CHARTS[@]}"; do
        tag="$(chart_current_tag "${head}" "${chart}")"
        git rev-parse --verify --quiet "refs/tags/${tag}^{commit}" > /dev/null || die "chart tag ${tag} is missing"
        cur="$(chart_current_tag "${base_ref}" "${chart}")"
        local -A allowed=()
        while IFS= read -r -d '' p; do allowed["${p}"]=1; done < <(git diff --no-renames --name-only -z "refs/tags/${cur}" "${base_ref}" -- "charts/${chart}")
        while IFS= read -r -d '' p; do
          n=$((n + 1))
          if [[ -z "${allowed[${p}]:-}" ]]; then
            echo "::error::${p} differs from ${tag} and is not a chart patch path"
            bad=$((bad + 1))
          fi
        done < <(git diff --no-renames --name-only -z "refs/tags/${tag}" "${head}" -- "charts/${chart}")
        unset allowed
      done
      ((bad == 0)) || die "${bad} problem(s): paths outside the patch set differ from upstream, or upstream holds xs namespace paths"
      echo "identity OK: ${n} path(s) differ from upstream main ${up} and the chart tags, all inside the patch set"
      summary "identity: ${n} path(s) differ from upstream main ${up} and the chart tags, all inside the patch set"
      ;;
    parents)
      local p1 p2 np
      p1="$(git rev-parse "${head}^1")"
      local main_head
      main_head="$(git rev-parse "${base_ref}")"
      [[ "${p1}" == "${main_head}" ]] || die "first parent ${p1} is not the current ${XS_MAIN_BRANCH} head ${main_head}; the daily sync refreshes the PR, or merge ${XS_MAIN_BRANCH} into the branch"
      np="$(git rev-list --parents -n 1 "${head}" | wc -w)"
      if ((np == 3)); then
        p2="$(git rev-parse "${head}^2")"
        git merge-base --is-ancestor "${p2}" "origin/upstream/main" || die "second parent ${p2} is not on upstream main"
      fi
      echo "parents OK"
      ;;
    charts)
      for chart in "${XS_CHARTS[@]}"; do
        tag="$(chart_current_tag "${head}" "${chart}")"
        git rev-parse --verify --quiet "refs/tags/${tag}^{commit}" > /dev/null || die "chart tag ${tag} is missing"
        local app engine
        app="$(chart_field "${head}" "${chart}" appVersion)"
        [[ "${app}" == "$(xs_chart_app "${chart}" "${tag}")" ]] || die "${chart}: appVersion ${app} differs from ${tag}"
        [[ "$(chart_field "${head}" "${chart}" version)" =~ ^${tag#"${chart}"-}\+xs\.(0|[1-9][0-9]*)$ ]] || die "${chart}: chart version is not ${tag#"${chart}"-}+xs.N"
        engine="$(chart_engine_tag "${head}" "${chart}")"
        [[ "${engine}" =~ ^${app//./\\.}-xs\.(0|[1-9][0-9]*)$ ]] || die "${chart}: engineTag ${engine} does not match appVersion ${app}"
        local main_app main_engine
        main_app="$(chart_field "${base_ref}" "${chart}" appVersion)"
        if xs_ver_gt "${main_app}" "${app}"; then die "${chart}: appVersion ${app} is below ${main_app} on ${XS_MAIN_BRANCH} (a downgrade)"; fi
        main_engine="$(chart_engine_tag "${base_ref}" "${chart}")"
        if [[ "${XS_CHECK_ENGINE:-true}" == true ]]; then
          # The engine tag is a mutable tag. It must still resolve to the digest the sync
          # verified and recorded in the PR body, and that digest must be signed and
          # attested by the engine release identity.
          local repo got want=""
          repo="${XS_ENGINE_REGISTRY}/${XS_ENGINE_ORG}/${XS_CHART_ENGINE[${chart}]}"
          got="$(crane digest "${repo}:${engine}")" || die "${chart}: cannot resolve ${repo}:${engine}"
          if [[ -n "${body_file}" ]]; then
            want="$(sed -n -E "s/^<!-- xs-sync:engine ${chart} (sha256:[0-9a-f]{64}) -->\$/\\1/p" "${body_file}" | head -n1)"
          fi
          if [[ "${engine}" != "${main_engine}" && -z "${want}" ]]; then die "${chart}: the PR body records no verified digest for ${engine}"; fi
          if [[ -n "${want}" && "${want}" != "${got}" ]]; then die "${chart}: ${repo}:${engine} resolves to ${got}, the sync verified ${want}"; fi
          xs_engine_trusted "${XS_CHART_ENGINE[${chart}]}" "${repo}" "${got}" || die "${chart}: ${repo}:${engine} (${got}) is not signed and attested by $(xs_engine_identity "${XS_CHART_ENGINE[${chart}]}")"
        fi
        echo "charts OK: ${chart} ${tag}, engine ${engine}"
        summary "charts: ${chart} ${tag}, engine ${engine}"
      done
      ;;
    *) die "unknown check ${what}" ;;
  esac
}

# ---------------------------------------------------------------------------
# flagdiff
# ---------------------------------------------------------------------------
build_binary() {
  local dir="$1" out="$2"
  (cd "${dir}" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "${out}" "${XS_BINARY_PKG}")
}

# help_text <bin> <flag>: print the help output, or nothing when the binary does
# not define the flag (loki has -help only, mimir and tempo also have -help-all).
help_text() {
  local bin="$1" flag="$2" rc=0 text
  text="$("${bin}" "${flag}" 2>&1)" || rc=$?
  # The flag package exits 0 for -help and 2 for an undefined flag.
  if ((rc != 0 && rc != 2)); then die "${bin} ${flag} exited ${rc}"; fi
  if [[ "${text}" == "flag provided but not defined:"* ]]; then return 0; fi
  printf '%s\n' "${text}"
}

# flag_names <help-file>...: flag names from help output, sorted, unique.
flag_names() {
  { grep -h -oE '^ +-[A-Za-z0-9_.-]+' "$@" || true; } | tr -d ' ' | LC_ALL=C sort -u
}

# flag_report <old-bin> <new-bin> <out.md>
flag_report() {
  local old_bin="$1" new_bin="$2" out="$3" work flag text_flag="" f
  work="$(mktemp -d)"
  for flag in ${XS_HELP_FLAGS}; do
    help_text "${old_bin}" "${flag}" > "${work}/old${flag}.txt"
    help_text "${new_bin}" "${flag}" > "${work}/new${flag}.txt"
    # The last flag that produced output is the one whose text is diffed (-help-all
    # is the complete list where it exists).
    if [[ -s "${work}/new${flag}.txt" ]]; then text_flag="${flag}"; fi
  done
  [[ -n "${text_flag}" ]] || die "the binary printed no help for any of: ${XS_HELP_FLAGS}"
  local -a olds=() news=()
  for flag in ${XS_HELP_FLAGS}; do
    olds+=("${work}/old${flag}.txt")
    news+=("${work}/new${flag}.txt")
  done
  flag_names "${olds[@]}" > "${work}/names-old"
  flag_names "${news[@]}" > "${work}/names-new"
  local added removed
  added="$(LC_ALL=C comm -13 "${work}/names-old" "${work}/names-new" | wc -l)"
  removed="$(LC_ALL=C comm -23 "${work}/names-old" "${work}/names-new" | wc -l)"
  {
    echo "Flag set of the \`${XS_BINARY_NAME}\` binary (linux/amd64, ${XS_HELP_FLAGS}), main vs this PR."
    echo
    echo "- flags: $(wc -l < "${work}/names-old") before, $(wc -l < "${work}/names-new") after"
    echo "- added: ${added}, removed: ${removed}"
    if ((removed > 0)); then
      echo
      echo "Removed flags:"
      echo
      echo '```'
      LC_ALL=C comm -23 "${work}/names-old" "${work}/names-new" | awk 'NR <= 100' | xs_neutralize
      echo '```'
    fi
    if ((added > 0)); then
      echo
      echo "Added flags:"
      echo
      echo '```'
      LC_ALL=C comm -13 "${work}/names-old" "${work}/names-new" | awk 'NR <= 100' | xs_neutralize
      echo '```'
    fi
    echo
    echo "<details><summary>${text_flag} text diff (first 300 lines)</summary>"
    echo
    echo '```diff'
    { diff -u "${work}/old${text_flag}.txt" "${work}/new${text_flag}.txt" || true; } | awk 'NR <= 300' | xs_neutralize
    echo '```'
    echo
    echo "</details>"
  } > "${out}"
  # Help output is only a diff when the binaries print something; an empty flag set means the parse failed.
  [[ -s "${work}/names-new" ]] || die "no flags found in the help output"
}

cmd_flagdiff() {
  local old_dir="$1" new_dir="$2" out="$3" work
  if [[ -z "${XS_BINARY_PKG}" ]]; then
    printf 'No binary in this repository, flag diff skipped.\n' > "${out}"
    return 0
  fi
  work="$(mktemp -d)"
  build_binary "${old_dir}" "${work}/old"
  build_binary "${new_dir}" "${work}/new"
  flag_report "${work}/old" "${work}/new" "${out}"
  cat "${out}"
}

# ---------------------------------------------------------------------------
# failure issue
# ---------------------------------------------------------------------------
cmd_issue_failed() {
  local url="${1:?run url required}" num title="sync: failed"
  [[ "${url}" =~ ^https://github\.com/[A-Za-z0-9._/-]+$ ]] || die "bad run url"
  ensure_label sync-failed D93F0B "xs-sync run failed"
  num="$(issue_find "${title}" sync-failed "${XS_ISSUE_AUTHOR_ACTIONS}")"
  if [[ -n "${num}" ]]; then
    gh issue comment "${num}" --body "Failed again: ${url}" > /dev/null
    echo "commented on #${num}"
  else
    gh issue create --title "${title}" --label sync-failed --body "xs-sync failed: ${url}"
  fi
}

# ---------------------------------------------------------------------------
main() {
  local cmd="${1:-}"
  shift || true
  case "${cmd}" in
    mirror) cmd_mirror "$@" ;;
    pick) xs_pick "$@" ;;
    engines) cmd_engines "$@" ;;
    ghcr-login) cmd_ghcr_login ;;
    disable-upstream-workflows) cmd_disable_workflows ;;
    detect) cmd_detect "$@" ;;
    open-heads) cmd_open_heads "$@" ;;
    build) cmd_build "$@" ;;
    supersede) cmd_supersede "$@" ;;
    rehearse) cmd_rehearse "$@" ;;
    check) cmd_check "$@" ;;
    flagdiff) cmd_flagdiff "$@" ;;
    flagreport) flag_report "$@" ;;
    body-fill) xs_body_fill "$@" ;;
    issue-failed) cmd_issue_failed "$@" ;;
    *)
      sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' >&2
      exit 2
      ;;
  esac
}

if [[ "${XS_SYNC_SOURCE_ONLY:-}" != "1" ]]; then main "$@"; fi
