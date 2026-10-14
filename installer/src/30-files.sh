# 30-files.sh [L1a]: hashing, atomic writes, backups, link resolution, payload
# files by policy (replace, agent, create-only), the doctrine block, removal.
#
# Counters and lists the summary reads (set in the main shell, never inside a
# command substitution): N_WRITTEN N_UNCHANGED N_REPLACED, KEPT_LIST,
# LEFT_LIST, REMOVED_LIST, REPLACED_LIST, NOT_INSTALLED_LIST (1 name per line;
# a not-installed line is the name, then the reason in parentheses).
# KEPT_LIST holds a file the user changed or had before Conductor; a file that
# could not be written for any other reason goes to NOT_INSTALLED_LIST.

N_WRITTEN=0
N_UNCHANGED=0
N_REPLACED=0
KEPT_LIST=""
LEFT_LIST=""
REMOVED_LIST=""
REPLACED_LIST=""
NOT_INSTALLED_LIST=""
LINKED_LIST=""
SETTINGS_BACKED_UP=0

# sha256_of FILE: prints the hex digest; returns 1 when it cannot (the file is
# missing or cannot be read, with no message of the shell's own). The bytes go
# in on stdin, so a file name with odd characters never reaches the hash tool.
sha256_of() {
  [ -f "$1" ] && [ -r "$1" ] || return 1
  sha256_stdin < "$1" 2>/dev/null
}

# sha256_stdin: the same for bytes on stdin.
sha256_stdin() {
  local out=""
  if command -v sha256sum >/dev/null 2>&1; then
    out="$(sha256sum 2>/dev/null | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    out="$(shasum -a 256 2>/dev/null | awk '{print $1}')"
  elif command -v openssl >/dev/null 2>&1; then
    out="$(openssl dgst -sha256 2>/dev/null | awk '{print $NF}')"
  fi
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# mode_of FILE: the octal mode (GNU stat first, then BSD stat).
mode_of() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null
}

# resolve_link PATH: follows a chain of symbolic links on PATH itself and prints
# the final path (a dangling link yields its would-be target). Portable: uses
# readlink without -f. Returns 1 on a loop (more than 40 hops).
resolve_link() {
  local p="$1" n=0 t d
  while [ -L "$p" ]; do
    n=$((n + 1))
    [ "$n" -le 40 ] || return 1
    t="$(readlink "$p")" || return 1
    case "$t" in
      /*) p="$t" ;;
      *) d="$(dirname "$p")"; p="$d/$t" ;;
    esac
  done
  printf '%s\n' "$p"
}

# atomic_write DEST MODE: stdin becomes DEST. The data goes to a temp file in the
# same folder (mode 600 from creation), is given MODE, then renamed over the
# target. A symbolic link at DEST is resolved first, so the link stays a link.
# Run as root, the new file keeps the owner of the file it replaces.
atomic_write() {
  local dest="$1" mode="$2" target dir tmp owner=""
  target="$(resolve_link "$dest")" || { err "too many symbolic links: $dest"; return 1; }
  if [ -d "$target" ]; then err "$target is a folder, not a file"; return 1; fi
  dir="$(dirname "$target")"
  mkdir -p "$dir" || return 1
  if [ "$(id -u 2>/dev/null || echo 1)" = "0" ] && [ -e "$target" ]; then
    owner="$(stat -c '%u:%g' "$target" 2>/dev/null || stat -f '%u:%g' "$target" 2>/dev/null || true)"
  fi
  tmp="$(mktemp "$dir/.conductor-tmp.XXXXXX")" || return 1
  if ! cat > "$tmp"; then rm -f "$tmp"; return 1; fi
  if ! chmod "$mode" "$tmp"; then rm -f "$tmp"; return 1; fi
  if [ -n "$owner" ]; then chown "$owner" "$tmp" 2>/dev/null || true; fi
  if ! mv -f "$tmp" "$target"; then rm -f "$tmp"; return 1; fi
}

# root_of PATH: the config root that owns PATH (the Codex skills folder belongs
# to the Codex root). Returns 1 for a path outside every root.
root_of() {
  case "$1" in
    "$CLAUDE_DIR"/*) printf '%s' "$CLAUDE_DIR" ;;
    "$CODEX_DIR"/*) printf '%s' "$CODEX_DIR" ;;
    "$AGENTS_SKILLS_DIR"/*) printf '%s' "$CODEX_DIR" ;;
    *) return 1 ;;
  esac
}

# backup_file FILE: copies FILE into {root}/conductor/backups/ (folder mode 700,
# file keeps its mode) and echoes the backup path. Never writes beside FILE.
backup_file() {
  local src="$1" root dir rel base bak n=0
  root="$(root_of "$src")" || { err "will not back up a file outside the config folders: $src"; return 1; }
  dir="$root/conductor/backups"
  mkdir -p "$dir" || return 1
  chmod 700 "$dir" || return 1
  case "$src" in
    "$root"/*) rel="${src#"$root"/}" ;;
    *) rel="agents/${src#"$AGENTS_SKILLS_DIR"/}" ;;
  esac
  base="$dir/${rel//\//__}.bak.$STAMP"
  bak="$base"
  while [ -e "$bak" ]; do n=$((n + 1)); bak="$base.$n"; done
  cp -p "$src" "$bak" || return 1
  printf '%s' "$bak"
}

# file_root_dir ID: the folder that the dest of file ID is relative to.
file_root_dir() {
  case "$(file_harness "$1")" in
    claude) printf '%s' "$CLAUDE_DIR" ;;
    codex)
      if [ "$(file_root "$1")" = "agents_skills" ]; then
        printf '%s' "$AGENTS_SKILLS_DIR"
      else
        printf '%s' "$CODEX_DIR"
      fi
      ;;
    *) return 1 ;;
  esac
}

# mroot_of_id ID: the config root whose install record lists file ID.
mroot_of_id() {
  case "$(file_harness "$1")" in
    claude) printf '%s' "$CLAUDE_DIR" ;;
    codex) printf '%s' "$CODEX_DIR" ;;
    *) return 1 ;;
  esac
}

# rootdir_for MROOT ROOTKEY: the folder a record entry's dest is relative to.
rootdir_for() {
  if [ "$2" = "agents_skills" ]; then printf '%s' "$AGENTS_SKILLS_DIR"; else printf '%s' "$1"; fi
}

# harness_of_mroot MROOT: claude or codex.
harness_of_mroot() {
  if [ "$1" = "$CODEX_DIR" ] && [ "$1" != "$CLAUDE_DIR" ]; then printf 'codex'; else printf 'claude'; fi
}

# path_unsafe PATH: true when PATH holds a character that cannot be put inside a
# double-quoted shell word safely: a double quote, $, a backtick, a backslash
# or a line break.
path_unsafe() {
  case "$1" in
    *'"'*|*'$'*|*'`'*|*'\'*|*$'\n'*|*$'\r'*|*$'\t'*) return 0 ;;
  esac
  return 1
}

# safe_rel DEST: true for a relative path that stays inside its folder and holds
# no control character.
safe_rel() {
  case "$1" in
    ""|/*|*..*|*'\'*) return 1 ;;
  esac
  case "$1" in
    *[[:cntrl:]]*) return 1 ;;
  esac
  return 0
}

# clean_name TEXT: TEXT with control characters removed and line breaks turned
# into spaces, safe to print. Names taken from an install record go through it.
clean_name() {
  printf '%s' "$1" | sanitize_text | tr '\n' ' '
}

# via_link ROOTDIR DEST: true when ROOTDIR/DEST, or any folder below ROOTDIR on
# the way to it, is a symbolic link. ROOTDIR itself may be a link.
via_link() {
  local p="$1" rest="$2" seg
  while [ -n "$rest" ]; do
    seg="${rest%%/*}"
    if [ "$seg" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
    p="$p/$seg"
    if [ -L "$p" ]; then return 0; fi
  done
  return 1
}

# link_folder_of ROOTDIR DEST: prints the first folder below ROOTDIR on the way
# to DEST that is a symbolic link (DEST itself is not looked at) and returns 0;
# returns 1 when there is none. Install writes through such a folder; uninstall
# never removes anything through it.
link_folder_of() {
  local p="$1" rest seg
  case "$2" in
    */*) rest="$(dirname "$2")" ;;
    *) return 1 ;;
  esac
  while [ -n "$rest" ] && [ "$rest" != "." ]; do
    seg="${rest%%/*}"
    if [ "$seg" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
    p="$p/$seg"
    if [ -L "$p" ]; then printf '%s' "$p"; return 0; fi
  done
  return 1
}

# say_wrote_through ROOTDIR DEST: after a write (or, in a dry run, a would-write) to
# DEST, says once per run, for each linked folder on the way to it, that the file went
# through the link and that uninstall leaves it there.
say_wrote_through() {
  local link
  link="$(link_folder_of "$1" "$2")" || return 0
  case $'\n'"$LINKED_LIST" in *$'\n'"$link"$'\n'*) return 0 ;; esac
  LINKED_LIST="${LINKED_LIST}$link"$'\n'
  if [ "${DRY_RUN:-0}" = "1" ]; then
    note_wrapped info 72 "" "would write through the symbolic link $link (uninstall will leave those files for you to remove)"
  else
    note_wrapped info 72 "" "wrote through the symbolic link $link (uninstall will leave those files for you to remove)"
  fi
}

# before_conductor MROOT DEST ROOTKEY: true when a file at DEST is not one
# Conductor ever wrote or knew: the install record holds no entry for it, and the
# folder held no 0.3.0 install.
before_conductor() {
  local mroot="$1" dest="$2" rkey="$3"
  if [ "$mroot" = "$CLAUDE_DIR" ] && [ "$EXISTING_CLAUDE" = "v030" ]; then return 1; fi
  if [ "$mroot" = "$CODEX_DIR" ] && [ "$EXISTING_CODEX" = "v030" ]; then return 1; fi
  [ -z "$(manifest_sha_of "$mroot" "$dest" "$rkey")" ]
}

note_left() { # $1=name: a file a removal did not touch (a link, not a plain file)
  LEFT_LIST="${LEFT_LIST}$1"$'\n'
}
note_kept() { # $1=name
  KEPT_LIST="${KEPT_LIST}$1"$'\n'
}
note_not_installed() { # $1=name $2=reason: a file that was not written, and not because the user changed it
  NOT_INSTALLED_LIST="${NOT_INSTALLED_LIST}$1 ($2)"$'\n'
}

# ---- known hashes -------------------------------------------------------------

# payload_hash ID: the sha256 of the payload bytes of file ID.
payload_hash() {
  payload_emit "$1" | sha256_stdin
}

# prior_hash_has HARNESS DEST SHA: true when SHA is a released hash of that file.
prior_hash_has() {
  emit_prior_hashes | awk -v h="$3" -v k="$1:$2" '$1 == h && $3 == k { f = 1 } END { exit !f }'
}

# known_hash HARNESS ROOTKEY DEST SHA MROOT: true when SHA is a hash Conductor
# knows for DEST: a released hash, the current payload of any file entry with
# that destination, or the hash the install record holds for it.
known_hash() {
  local harness="$1" rkey="$2" dest="$3" sha="$4" mroot="$5" other rec
  if prior_hash_has "$harness" "$dest" "$sha"; then return 0; fi
  for other in $FILE_IDS; do
    [ "$(file_harness "$other")" = "$harness" ] || continue
    [ "$(file_root "$other")" = "$rkey" ] || continue
    if [ "$(file_dest "$other")" = "$dest" ] || [ "$(file_also "$other")" = "$dest" ]; then
      [ "$(payload_hash "$other")" = "$sha" ] && return 0
    fi
  done
  if [ -n "$mroot" ]; then
    rec="$(manifest_sha_of "$mroot" "$dest" "$rkey")"
    if [ -n "$rec" ] && [ "$rec" = "$sha" ]; then return 0; fi
  fi
  return 1
}

# ---- payload files ---------------------------------------------------------------

# place_file ID DEST ROOTDIR MROOT POLICY: the shared logic for 1 destination.
# POLICY: replace (a Conductor-owned file), agent (the same for an agent file),
# create-only (written only when missing), also (a reference copy, refreshed).
# REQ-INS-005: a file that differs from every known hash is the user's; it is
# replaced only after a backup and a yes, or with --replace-modified.
place_file() {
  local id="$1" dest="$2" rdir="$3" mroot="$4" policy="$5"
  local target mode rkey real cur new hv bak="" action="" exists=0 asked
  target="$rdir/$dest"
  mode="$(file_mode "$id")"
  rkey="$(file_root "$id")"
  hv="$(harness_of_mroot "$mroot")"
  if [ -d "$target" ] && [ ! -L "$target" ]; then
    warn "did not write $dest (a folder is there)"
    note_not_installed "$dest" "a folder is there"
    return 0
  fi
  real="$target"
  if [ -L "$target" ]; then
    real="$(resolve_link "$target")" || { warn "did not write $dest (links loop)"; note_not_installed "$dest" "the symbolic links loop"; return 0; }
  fi
  if [ -d "$real" ]; then
    warn "did not write $dest (a folder is there)"
    note_not_installed "$dest" "a folder is there"
    return 0
  fi
  if [ -f "$real" ]; then exists=1; fi
  new="$(payload_hash "$id")" || { err "cannot hash the payload of $id"; return 1; }
  if [ "$exists" = 0 ]; then
    action="write"
  else
    cur="$(sha256_of "$real")" || { warn "did not write $dest (it cannot be read; check its permissions)"; note_not_installed "$dest" "it cannot be read; check its permissions"; return 0; }
    if [ "$policy" = "create-only" ]; then
      ok "$dest (yours, left as it is)"
      N_UNCHANGED=$((N_UNCHANGED + 1))
      return 0
    elif [ "$cur" = "$new" ]; then
      action="same"
    elif known_hash "$hv" "$rkey" "$dest" "$cur" "$mroot"; then
      action="replace"
    elif [ "$policy" = "also" ]; then
      action="replace"
    elif [ "${OPT_REPLACE_MODIFIED:-0}" = "1" ]; then
      action="replace"
    elif ! no_prompt; then
      asked=0
      warn "$(clean_name "$dest") has changes of yours"
      if ask_yn "Replace it with the new version? (a backup is kept)" n; then asked=1; fi
      if [ "$asked" = 1 ]; then action="replace"; else action="keep"; fi
    else
      action="keep"
    fi
  fi
  case "$action" in
    same)
      ok "$dest (unchanged)"
      N_UNCHANGED=$((N_UNCHANGED + 1))
      manifest_add_file "$mroot" "$id" "$dest" "$policy"
      return 0
      ;;
    keep)
      if before_conductor "$mroot" "$dest" "$rkey"; then
        warn "kept your $dest (it was there before Conductor)"
      else
        warn "kept $dest (you changed it)"
      fi
      note_kept "$dest"
      return 0
      ;;
  esac
  if [ "${DRY_RUN:-0}" = "1" ]; then
    if [ "$action" = "write" ]; then info "would write $dest"; else info "would replace $dest (after a backup)"; fi
    say_wrote_through "$rdir" "$dest"
    return 0
  fi
  if [ "$action" = "replace" ]; then
    bak="$(backup_file "$target")" || { err "could not back up $target"; return 1; }
  fi
  payload_emit "$id" | atomic_write "$target" "$mode" || { err "could not write $target"; return 1; }
  if [ "$action" = "replace" ]; then
    ok "replaced $dest"
    info "backup: $bak"
    N_REPLACED=$((N_REPLACED + 1))
    REPLACED_LIST="${REPLACED_LIST}$dest"$'\n'
  else
    ok "wrote $dest"
    N_WRITTEN=$((N_WRITTEN + 1))
  fi
  say_wrote_through "$rdir" "$dest"
  manifest_add_file "$mroot" "$id" "$dest" "$policy"
}

# install_payload_file ID: writes 1 payload file into its own root and records
# it. Policy doctrine-block belongs to write_doctrine_block.
install_payload_file() {
  install_payload_file_in "$1" "$(file_root_dir "$1")" "$(mroot_of_id "$1")"
}

# install_payload_file_in ID ROOTDIR MROOT: the same, into another folder (the
# launcher files also go into the Codex root).
install_payload_file_in() {
  local id="$1" rdir="$2" mroot="$3" policy dest also
  policy="$(file_policy "$id")"
  dest="$(file_dest "$id")"
  case "$policy" in
    doctrine-block) return 0 ;;
    create-only)
      place_file "$id" "$dest" "$rdir" "$mroot" create-only || return 1
      also="$(file_also "$id")"
      if [ -n "$also" ]; then place_file "$id" "$also" "$rdir" "$mroot" also || return 1; fi
      ;;
    replace|agent) place_file "$id" "$dest" "$rdir" "$mroot" "$policy" || return 1 ;;
    *) warn "unknown policy $policy for $id"; return 1 ;;
  esac
}

# remove_entry MROOT DEST ROOTKEY ID SHA POLICY: removes 1 recorded file when it
# is safe: a regular file inside the folder, never through a symbolic link,
# whose hash is the recorded one or a released one. Anything else is named and
# left alone. Prints 1 line. The record entry is dropped either way.
remove_entry() {
  local mroot="$1" dest="$2" rkey="$3" id="$4" sha="$5" policy="$6" rdir path cur hv label
  rdir="$(rootdir_for "$mroot" "$rkey")"
  hv="$(harness_of_mroot "$mroot")"
  label="$(clean_name "$dest")"
  if ! safe_rel "$dest"; then
    warn "left alone: $label (it points outside the folder)"
    note_left "$label"
    return 0
  fi
  path="$rdir/$dest"
  if [ "$policy" = "create-only" ]; then
    if [ -e "$path" ] || [ -L "$path" ]; then
      info "kept $label (yours; Conductor never removes it)"
      note_kept "$label"
    fi
    [ "${DRY_RUN:-0}" = "1" ] || manifest_rm_file "$mroot" "$dest" "$rkey"
    return 0
  fi
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    [ "${DRY_RUN:-0}" = "1" ] || manifest_rm_file "$mroot" "$dest" "$rkey"
    return 0
  fi
  if via_link "$rdir" "$dest"; then
    warn "left alone: $label (a symbolic link)"
    note_left "$label"
    return 0
  fi
  if [ ! -f "$path" ]; then
    warn "left alone: $label (not a regular file)"
    note_left "$label"
    return 0
  fi
  cur="$(sha256_of "$path")" || { warn "left alone: $label (it cannot be read; check its permissions)"; note_left "$label"; return 0; }
  if [ "$cur" != "$sha" ] && ! known_hash "$hv" "$rkey" "$dest" "$cur" ""; then
    warn "kept $label (you changed it)"
    note_kept "$label"
    [ "${DRY_RUN:-0}" = "1" ] || manifest_rm_file "$mroot" "$dest" "$rkey"
    return 0
  fi
  if [ "${DRY_RUN:-0}" = "1" ]; then
    info "would remove $label"
    return 0
  fi
  if rm -f "$path"; then
    ok "removed $label"
    REMOVED_LIST="${REMOVED_LIST}$label"$'\n'
    manifest_rm_file "$mroot" "$dest" "$rkey"
    prune_empty_dirs "$rdir" "$dest"
  else
    warn "could not remove $label"
  fi
}

# remove_payload_file ID: removes file ID (and its "also" copy) if safe.
remove_payload_file() {
  local id="$1" mroot dest rkey also
  mroot="$(mroot_of_id "$id")"
  dest="$(file_dest "$id")"
  rkey="$(file_root "$id")"
  remove_entry "$mroot" "$dest" "$rkey" "$id" "$(manifest_sha_of "$mroot" "$dest" "$rkey")" "$(file_policy "$id")"
  also="$(file_also "$id")"
  if [ -n "$also" ]; then
    remove_entry "$mroot" "$also" "$rkey" "$id" "$(manifest_sha_of "$mroot" "$also" "$rkey")" replace
  fi
}

# prune_empty_dirs ROOTDIR RELPATH: rmdir the folders on the way up from a
# removed file, stopping at the first folder that is not empty or at the root.
prune_empty_dirs() {
  local rdir="$1" rel="$2" d
  d="$(dirname "$rel")"
  while [ "$d" != "." ] && [ "$d" != "/" ] && [ -n "$d" ]; do
    [ -L "$rdir/$d" ] && return 0
    rmdir "$rdir/$d" 2>/dev/null || return 0
    d="$(dirname "$d")"
  done
}

# ---- the doctrine block ---------------------------------------------------------

# doctrine_id HARNESS: the id of the doctrine-block file of that harness.
doctrine_id() {
  local id
  for id in $FILE_IDS; do
    if [ "$(file_harness "$id")" = "$1" ] && [ "$(file_policy "$id")" = "doctrine-block" ]; then
      printf '%s' "$id"
      return 0
    fi
  done
  return 1
}

# marker_state FILE: none, paired or malformed (managed marker lines).
marker_state() {
  local b e bl el
  b="$(grep -c '^<!-- BEGIN CONDUCTOR (managed)' "$1" 2>/dev/null || true)"
  e="$(grep -c '^<!-- END CONDUCTOR (managed)' "$1" 2>/dev/null || true)"
  if [ "${b:-0}" = 0 ] && [ "${e:-0}" = 0 ]; then printf 'none'; return 0; fi
  if [ "${b:-0}" = 1 ] && [ "${e:-0}" = 1 ]; then
    bl="$(grep -n '^<!-- BEGIN CONDUCTOR (managed)' "$1" | head -1 | cut -d: -f1)"
    el="$(grep -n '^<!-- END CONDUCTOR (managed)' "$1" | head -1 | cut -d: -f1)"
    if [ "$bl" -lt "$el" ]; then printf 'paired'; return 0; fi
  fi
  printf 'malformed'
}

# write_doctrine_block HARNESS: writes the managed block into CLAUDE.md or
# AGENTS.md. Paired markers: the block is replaced where it stands. None: the
# block is appended. Malformed: the file is backed up and left alone. Every byte
# outside the markers stays as it was. A symbolic link stays a link.
write_doctrine_block() {
  local harness="$1" id file real state blk new mode mroot folder dname bak="" before=""
  case "$harness" in
    claude) [ "$HAVE_CLAUDE" = 1 ] || return 0 ;;
    codex) [ "$HAVE_CODEX" = 1 ] || return 0 ;;
    *) return 1 ;;
  esac
  id="$(doctrine_id "$harness")" || return 0
  section_heading "$harness"
  mroot="$(mroot_of_id "$id")"
  dname="$(file_dest "$id")"
  file="$(file_root_dir "$id")/$dname"
  folder="$mroot/conductor"
  real="$file"
  if [ -L "$file" ]; then
    real="$(resolve_link "$file")" || { warn "did not write $dname (links loop)"; note_not_installed "$dname" "the symbolic links loop"; return 0; }
  fi
  if [ -d "$real" ]; then warn "did not write $dname (a folder is there)"; note_not_installed "$dname" "a folder is there"; return 0; fi
  state="none"
  if [ -f "$real" ]; then state="$(marker_state "$real")"; fi
  if [ "$state" = "malformed" ]; then
    if [ "${DRY_RUN:-0}" = "1" ]; then
      info "would back up $dname and leave it (its markers are broken)"
      return 0
    fi
    bak="$(backup_file "$file")" || return 1
    warn "$dname has broken Conductor markers; left as it is"
    info "backup: $bak"
    info "fix the markers by hand, then run the installer again"
    return 0
  fi
  # What the file was before the block went in, for the record: the uninstall puts the file
  # back the way it was (absent, empty, text with a final line feed, text without one).
  if [ "$state" = "none" ]; then
    if [ ! -f "$real" ]; then
      before="absent"
    elif [ ! -s "$real" ]; then
      before="empty"
    elif [ -n "$(tail -c 1 "$real")" ]; then
      before="no-newline"
    else
      before="text"
    fi
  fi
  blk="$(mktemp "${TMPDIR:-/tmp}/conductor-block.XXXXXX")" || return 1
  new="$(mktemp "${TMPDIR:-/tmp}/conductor-doc.XXXXXX")" || { rm -f "$blk"; return 1; }
  {
    printf '%s\n' "$BEGIN_MARKER"
    payload_emit "$id"
    printf '\nConductor folder: %s\n' "$folder"
    printf '%s\n' "$END_MARKER"
  } > "$blk"
  if [ "$state" = "paired" ]; then
    LC_ALL=C awk -v blockfile="$blk" '
      /^<!-- BEGIN CONDUCTOR \(managed\)/ && !done { while ((getline line < blockfile) > 0) print line; close(blockfile); skip = 1; next }
      skip && /^<!-- END CONDUCTOR \(managed\)/ { skip = 0; done = 1; next }
      skip { next }
      { print }' "$real" > "$new"
  elif [ -f "$real" ] && [ -s "$real" ]; then
    {
      cat "$real"
      if [ -n "$(tail -c 1 "$real")" ]; then printf '\n'; fi
      printf '\n'
      cat "$blk"
    } > "$new"
  else
    cat "$blk" > "$new"
  fi
  if [ -f "$real" ] && cmp -s "$new" "$real"; then
    ok "$dname block (unchanged)"
    rm -f "$blk" "$new"
    manifest_set "$mroot" doctrine_block true
    return 0
  fi
  if [ "${DRY_RUN:-0}" = "1" ]; then
    if [ -f "$real" ]; then info "would update the Conductor block in $dname (after a backup)"; else info "would write $dname with the Conductor block"; fi
    rm -f "$blk" "$new"
    return 0
  fi
  mode=644
  if [ -f "$real" ]; then
    mode="$(mode_of "$real")"
    bak="$(backup_file "$file")" || { rm -f "$blk" "$new"; return 1; }
  fi
  if ! atomic_write "$file" "$mode" < "$new"; then
    rm -f "$blk" "$new"
    err "could not write $file"
    return 1
  fi
  rm -f "$blk" "$new"
  ok "$dname block written"
  if [ -n "$bak" ]; then info "backup: $bak"; fi
  manifest_set "$mroot" doctrine_block true
  if [ -n "$before" ]; then manifest_set "$mroot" doctrine_file "$(json_quote "$before")"; fi
}

# strip_doctrine_block HARNESS: removes the managed block, after a backup. The
# blank line that separated it from the user's text goes with it when the block
# was the last thing in the file, and a file that had no final line feed before the
# install has none again. A file left empty is removed only when the install created
# it (the record says absent, or holds nothing about it, as a 0.3.0 upgrade does); a
# file that existed before, even an empty one, stays.
strip_doctrine_block() {
  local harness="$1" id file real state new bak mode dname mroot before nonl=0
  id="$(doctrine_id "$harness")" || return 0
  dname="$(file_dest "$id")"
  file="$(file_root_dir "$id")/$dname"
  real="$file"
  if [ -L "$file" ]; then real="$(resolve_link "$file")" || return 0; fi
  [ -f "$real" ] || return 0
  state="$(marker_state "$real")"
  case "$state" in
    none) return 0 ;;
    malformed)
      warn "$dname markers look broken; left as it is. Remove the block by hand."
      return 0
      ;;
  esac
  if [ "${DRY_RUN:-0}" = "1" ]; then info "would remove the Conductor block from $dname"; return 0; fi
  new="$(mktemp "${TMPDIR:-/tmp}/conductor-doc.XXXXXX")" || return 1
  mroot="$(mroot_of_id "$id")"
  before="$(manifest_get "$mroot" doctrine_file)"
  if [ "$before" = "no-newline" ]; then nonl=1; fi
  LC_ALL=C awk -v nonl="$nonl" '
    /^<!-- BEGIN CONDUCTOR \(managed\)/ && !done { skip = 1; next }
    skip && /^<!-- END CONDUCTOR \(managed\)/ { skip = 0; done = 1; next }
    skip { next }
    done { after = after $0 "\n"; if ($0 !~ /^[ \t]*$/) tail = 1 }
    { if (!done) before[++n] = $0 }
    END {
      last = n
      if (!tail && last > 0 && before[last] ~ /^[ \t]*$/) last--
      for (i = 1; i <= last; i++) {
        if (i == last && nonl == 1 && !tail) printf "%s", before[i]
        else print before[i]
      }
      if (tail) printf "%s", after
    }' "$real" > "$new"
  bak="$(backup_file "$file")" || { rm -f "$new"; return 1; }
  if [ ! -s "$new" ] && { [ "$before" = "empty" ] || [ "$before" = "text" ] || [ "$before" = "no-newline" ]; }; then
    rm -f "$new"
    : > "$real"
    ok "removed the Conductor block from $dname (the file stays, as it was before the install)"
  elif [ ! -s "$new" ]; then
    rm -f "$new"
    if [ -L "$file" ]; then : > "$real"; else rm -f "$file"; fi
    ok "removed $dname (it held only the Conductor block)"
  else
    mode="$(mode_of "$real")"
    if ! atomic_write "$file" "$mode" < "$new"; then rm -f "$new"; err "could not write $file"; return 1; fi
    rm -f "$new"
    ok "removed the Conductor block from $dname"
  fi
  info "backup: $bak"
}
