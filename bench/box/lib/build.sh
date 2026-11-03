# shellcheck shell=bash
# Incremental builds: work out which packages a commit range touches and rebuild only those
# (plus their dependents), in dependency order. See bench/README.md "Build path".

# Prints the useful part of a failed nx log: error lines with context, then the tail.
show_failure() {
  local logfile=$1
  sed 's/\x1b\[[0-9;]*m//g' "$logfile" | grep -iE -B2 -A6 'error|failed|cannot|ENOENT|EACCES' | head -n 120 >&2 || true
  echo "----- tail of $logfile" >&2
  tail -n 30 "$logfile" >&2
}

tree_label() {
  if [[ $1 == "$REPO_DIR" ]]; then echo base; else basename "$(dirname "$1")"; fi
}

# Sets BUILD_SET (packages to build, in BUILD_ORDER) and DEPS_CHANGED from a list of changed paths.
plan_build() {
  local path pkg dep
  declare -A wanted=()
  DEPS_CHANGED=0
  local full=0
  for path in "$@"; do
    case $path in
      bench/* | .github/* | *.md | .vscode/* | .claude/* | .cursor/*) ;;
      yarn.lock | package.json | .yarnrc.yml | .yarn/* | packages/*/package.json | packages/twenty-server/patches/*)
        DEPS_CHANGED=1
        full=1
        ;;
      packages/*)
        pkg=${path#packages/}
        pkg=${pkg%%/*}
        if [[ -v "PACKAGE_DEPENDENTS[$pkg]" ]]; then
          wanted[$pkg]=1
          for dep in ${PACKAGE_DEPENDENTS[$pkg]}; do wanted[$dep]=1; done
        fi
        ;;
      *) full=1 ;;
    esac
  done
  BUILD_SET=()
  for pkg in "${BUILD_ORDER[@]}"; do
    if [[ $full == 1 || -v "wanted[$pkg]" ]]; then BUILD_SET+=("$pkg"); fi
  done
}

# True when the change since the base commit adds or edits Lingui-marked strings in a package.
strings_changed() {
  local tree=$1 pkg=$2 base_sha=$3
  git -C "$tree" diff -U0 "$base_sha" HEAD -- "packages/$pkg/src" ':(exclude,glob)**/locales/**' 2>/dev/null |
    grep -E '^[+-][^+-]' |
    grep -Eq '(\bt`|msg`|<Trans\b|\bplural\(|\bselect\(|defineMessage|i18n\._|\bt\()'
}

# Brings a package's compiled catalogs up to date before it is built.
prepare_catalogs() {
  local tree=$1 pkg=$2 base_sha=$3 mode=$4
  [[ -v "LINGUI_LOCALE_DIRS[$pkg]" ]] || return 0
  local dir=${LINGUI_LOCALE_DIRS[$pkg]} start
  start=$(now_s)
  if [[ $mode == extract ]] || strings_changed "$tree" "$pkg" "$base_sha"; then
    log "lingui extract+compile for $pkg"
    nx_in "$tree" run "$pkg:lingui:extract" --output-style=static >"$BUILD_LOG_DIR/lingui-$pkg.log" 2>&1 ||
      { show_failure "$BUILD_LOG_DIR/lingui-$pkg.log"; die "lingui extract failed for $pkg"; }
    nx_in "$tree" run "$pkg:lingui:compile" --output-style=static >>"$BUILD_LOG_DIR/lingui-$pkg.log" 2>&1 ||
      { show_failure "$BUILD_LOG_DIR/lingui-$pkg.log"; die "lingui compile failed for $pkg"; }
    timing "lingui_${pkg}" $(($(now_s) - start))
  elif [[ -d "$LINGUI_OVERLAY_DIR/$pkg" ]]; then
    # Catalogs extracted on the base build, so strings missing from the committed catalogs still render.
    as_bench cp -a "$LINGUI_OVERLAY_DIR/$pkg/." "$tree/$dir/"
  fi
}

save_catalog_overlay() {
  local tree=$1 pkg
  for pkg in "${!LINGUI_LOCALE_DIRS[@]}"; do
    rm -rf "${LINGUI_OVERLAY_DIR:?}/$pkg"
    mkdir -p "$LINGUI_OVERLAY_DIR/$pkg"
    cp -a "$tree/${LINGUI_LOCALE_DIRS[$pkg]}/." "$LINGUI_OVERLAY_DIR/$pkg/"
  done
}

link_front_into_server() {
  local tree=$1
  as_bench mkdir -p "$tree/packages/twenty-server/dist"
  as_bench ln -sfn ../../twenty-front/build "$tree/packages/twenty-server/dist/front"
}

# Builds whatever BUILD_SET needs in tree. One nx run builds the server and/or front with their
# dependency tasks; the worktree's nx cache (seeded from the base build) skips unchanged packages.
# mode=extract runs Lingui extraction for every catalog package.
build_tree() {
  local tree=$1 base_sha=$2 mode=$3
  shift 3
  local -a set=("$@") targets=()
  local pkg logfile start front=0
  BUILD_LOG_DIR="$LOG_DIR/build/$(tree_label "$tree")"
  mkdir -p "$BUILD_LOG_DIR"
  chown -R "$BENCH_USER" "$BUILD_LOG_DIR"
  [[ ${#set[@]} -gt 0 ]] || { log "nothing to build"; return 0; }
  log "changed packages: ${set[*]}"
  for pkg in "${set[@]}"; do
    case $pkg in
      twenty-server) targets+=(twenty-server) ;;
      twenty-front) targets+=(twenty-front) front=1 ;;
    esac
  done
  if [[ $front == 1 ]]; then
    start=$(now_s)
    acquire_slot front-build "$FRONT_BUILD_SLOTS"
    timing front_build_queue $(($(now_s) - start))
  fi
  for pkg in "${set[@]}"; do
    prepare_catalogs "$tree" "$pkg" "$base_sha" "$mode" || { release_slot; die "catalogs failed for $pkg"; }
  done
  start=$(now_s)
  logfile="$BUILD_LOG_DIR/build.log"
  if ! (export NODE_OPTIONS="--max-old-space-size=${FRONT_BUILD_HEAP_MB:-7168}"
    nx_in "$tree" run-many -t build -p "$(IFS=,; echo "${targets[*]}")" --parallel=3 --output-style=static) >"$logfile" 2>&1; then
    release_slot
    show_failure "$logfile"
    die "build failed: ${targets[*]}"
  fi
  release_slot
  grep -E '^\s+Cache:|Successfully ran' "$logfile" | sed 's/^ */nx: /' >&2 || true
  timing build_nx $(($(now_s) - start))
  link_front_into_server "$tree"
}

install_dependencies() {
  local tree=$1 start
  start=$(now_s)
  log "yarn workspaces focus (${#FOCUS_WORKSPACES[@]} workspaces)"
  local logfile
  logfile="$LOG_DIR/yarn-$(tree_label "$tree").log"
  yarn_in "$tree" workspaces focus "${FOCUS_WORKSPACES[@]}" >"$logfile" 2>&1 ||
    { tail -n 60 "$logfile" >&2; die "yarn install failed"; }
  timing yarn_install $(($(now_s) - start))
}
