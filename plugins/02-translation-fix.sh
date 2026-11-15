#!/bin/sh
# nd2cn plugin: Simplified Chinese (zh_CN) translation quality fixes (was patch 02)
PLUGIN_NAME="translation-fix"
PLUGIN_DESC="Fix wrong, English and traditional-character strings in the zh_CN dictionaries"
PLUGIN_RISK="low"
#
# Which dictionary is live?
#   index.html loads resources/js/GuiResources.js. Every app listed in its
#   DICTIONARY_LIST with "true" (fmradio, mobile911, system, sysupdate,
#   vehsettings ...) has its dict loaded from resources/js/<app>/, NOT from
#   apps/<app>/js/ (see GuiFramework.js, the guiResources.DICTIONARY_LIST branch).
#   The apps/ copies are only a fallback if GuiResources is missing.
#
# What this patch fixes (all anchors verified against 74.00.324A):
#   A. apps/fmradio dict (fallback copy): the rbds_genre_* values are shifted
#      by one entry. Correct values are copied from the resources/ fmradio
#      dict. Also replaces 10 lines that use traditional characters (流行樂,
#      搖滾樂, 爵士樂, 國家/地區, 紀錄片, 類型, 烽煙節目). The live resources/
#      fmradio dict is already correct and is only read here, never modified.
#   B. resources/vehsettings dict: i-Activsense feature names left in English,
#      including inside reset/error/progress dialog strings. Stray ASCII spaces
#      next to the English name are dropped ("将 X 设置" -> "将X设置").
#      (No apps/vehsettings zh_CN dict exists on this firmware.)
#   C. resources/system dict: DidYouSay, EcoenergyApp, UseCommander,
#      WarnGuidanceApp.
#   D. resources/mobile911 dict: "移动 110" app title, plus traditional 電話/連接.
#   E. resources/sysupdate dict: English strings left untranslated.
#
# Idempotent: each file is run through its sed script into a staged copy. If
# the staged copy is byte-identical to the target, nothing is changed. Every
# file is published atomically on its own, so a partial failure leaves each
# dict either fully fixed or untouched; a re-run completes the rest.
# Commit: nd2cn_commit_staged (write-once pristine backup under PATCH_TAG,
# line-count truncation guard, atomic publish). nd2cn_backup_file inside it
# refuses a basename collision with a different path.
# POSIX sh. sed runs with LC_ALL=C, so multibyte UTF-8 strings are matched as
# plain byte sequences. That is safe: '"' (0x22) never occurs inside a
# multibyte UTF-8 sequence.

PATCH_TAG="02-translation-fix"

P02_GUI="${FIRMWARE_ROOT}/jci/gui"
P02_FM_APPS="$P02_GUI/apps/fmradio/js/fmradioAppDict_zh_CN.js"
P02_FM_RES="$P02_GUI/resources/js/fmradio/fmradioAppDict_zh_CN.js"
P02_VEH="$P02_GUI/resources/js/vehsettings/vehsettingsAppDict_zh_CN.js"
P02_SYS="$P02_GUI/resources/js/system/systemAppDict_zh_CN.js"
P02_M911="$P02_GUI/resources/js/mobile911/mobile911AppDict_zh_CN.js"
P02_SYSUPD="$P02_GUI/resources/js/sysupdate/sysupdateAppDict_zh_CN.js"

P02_FILES="$P02_FM_APPS $P02_VEH $P02_SYS $P02_M911 $P02_SYSUPD"

# ──────────────────────────────────────────────────────────────
# Internal helpers (all variables prefixed _p02_ to avoid clobbering the
# unprefixed globals used by helpers.sh functions)
# ──────────────────────────────────────────────────────────────

# _p02_verify FILE ABSENT_LIST PRESENT_LIST
# Lists are newline-separated fixed strings. Every ABSENT string must be missing
# from FILE and every PRESENT string must be found in it.
_p02_verify() {
    _p02_vf="$1"
    _p02_vrc=0
    while IFS= read -r _p02_l; do
        [ -n "$_p02_l" ] || continue
        if LC_ALL=C grep -qF -- "$_p02_l" "$_p02_vf"; then
            nd2cn_log "  still present: $_p02_l"
            _p02_vrc=1
        fi
    done <<EOF
$2
EOF
    while IFS= read -r _p02_l; do
        [ -n "$_p02_l" ] || continue
        if ! LC_ALL=C grep -qF -- "$_p02_l" "$_p02_vf"; then
            nd2cn_log "  missing: $_p02_l"
            _p02_vrc=1
        fi
    done <<EOF
$3
EOF
    return $_p02_vrc
}

# Print the "key value" pairs of all rbds_genre_* entries in FILE, sorted.
_p02_rbds_pairs() {
    LC_ALL=C sed -n 's/^[[:space:]]*"\(rbds_genre_[A-Za-z0-9_]*\)"[[:space:]]*:[[:space:]]*"\([^"]*\)".*$/\1 \2/p' "$1" | LC_ALL=C sort
}

# _p02_fix_file TARGET SED_SCRIPT ABSENT_LIST PRESENT_LIST DESC
# Returns 0 if the file was patched, already patched, or skipped with a
# warning. Returns 1 on an actual failure (the target is never left half-written).
_p02_fix_file() {
    _p02_t="$1"
    _p02_s="$2"
    _p02_absent="$3"
    _p02_present="$4"
    _p02_d="$5"

    if [ ! -f "$_p02_t" ]; then
        nd2cn_log "WARN: $_p02_d: $_p02_t not found (skip)"
        return 0
    fi

    _p02_staged=$(nd2cn_stage_file "$_p02_t")
    if [ -z "$_p02_staged" ]; then
        nd2cn_log "ERROR: $_p02_d: staging failed"
        return 1
    fi

    # Overwrite staged content in place (keeps the perms cp -p gave it).
    # Redirect instead of sed -i: -i is not POSIX.
    if ! LC_ALL=C sed -f "$_p02_s" "$_p02_t" > "$_p02_staged"; then
        nd2cn_log "ERROR: $_p02_d: sed failed"
        rm -f "$_p02_staged"
        return 1
    fi

    if cmp -s "$_p02_t" "$_p02_staged"; then
        rm -f "$_p02_staged"
        if _p02_verify "$_p02_t" "$_p02_absent" "$_p02_present"; then
            nd2cn_log "$_p02_d: already applied (skip)"
        else
            nd2cn_log "WARN: $_p02_d: anchors not found — firmware may differ (skip)"
        fi
        return 0
    fi

    if ! _p02_verify "$_p02_staged" "$_p02_absent" "$_p02_present"; then
        nd2cn_log "ERROR: $_p02_d: verification failed, file left untouched"
        rm -f "$_p02_staged"
        return 1
    fi

    # Backup (pristine, under PATCH_TAG) + truncation guard + atomic publish.
    # The sed scripts only substitute, never delete lines, so MAX_REMOVED is 0:
    # a staged copy with fewer lines than the target is a truncated write.
    # commit_staged removes the staged copy on any error.
    nd2cn_commit_staged "$_p02_t" "$_p02_staged" "$PATCH_TAG" 0 || {
        nd2cn_log "ERROR: $_p02_d: commit failed, file left untouched"
        return 1
    }
    nd2cn_log "$_p02_d: fixed"
    return 0
}

# ──────────────────────────────────────────────────────────────
# Sed scripts (written to a temp dir; quoted heredocs, no shell expansion)
# ──────────────────────────────────────────────────────────────
_p02_write_scripts() {
    _p02_tmp="$1"

    # A. fmradio (apps/ fallback copy).
    # A1: rbds_genre_* values copied from the resources/ dict. The value is
    #     escaped for a sed replacement (\ & |) before the s command is built.
    #     Indentation and key of the target line are kept, only the value changes.
    LC_ALL=C sed -n '/^[[:space:]]*"rbds_genre_[A-Za-z0-9_]*"[[:space:]]*:[[:space:]]*"[^"]*"/{
s/[\\&|]/\\&/g
s/^[[:space:]]*"\(rbds_genre_[A-Za-z0-9_]*\)"[[:space:]]*:[[:space:]]*"\([^"]*\)".*$/s|^\\([[:space:]]*"\1"[[:space:]]*:[[:space:]]*"\\)[^"]*"|\\1\2"|/p
}' "$P02_FM_RES" > "$_p02_tmp/fm.sed" || return 1
    if [ ! -s "$_p02_tmp/fm.sed" ]; then
        nd2cn_log "ERROR: no rbds_genre_* entries found in $P02_FM_RES"
        return 1
    fi
    # A2: traditional -> simplified (Pop, Rock, Jazz, Country, Documentary,
    #     GenreRock, GenreOther, GenrePhoneIn, GenreJazz, GenreCountry)
    cat >> "$_p02_tmp/fm.sed" <<'EOF'
s|流行樂|流行乐|g
s|搖滾樂|摇滚乐|g
s|爵士樂|爵士乐|g
s|國家/地區|乡村音乐|g
s|紀錄片|纪录片|g
s|類型|类型|g
s|烽煙節目|热线直播|g
EOF

    # B. vehsettings: English feature names -> Chinese, in every string.
    #    " \{0,1\}" eats one ASCII space on either side; no target is adjacent
    #    to other ASCII words, so this only removes stray CJK/Latin spacing.
    #    "Smart Brake Support" is not a substring of "Smart City Brake Support".
    cat > "$_p02_tmp/veh.sed" <<'EOF'
s| \{0,1\}Adaptive LED Headlights \{0,1\}|自适应LED大灯|g
s| \{0,1\}Distance Recognition Support System \{0,1\}|距离识别辅助系统|g
s| \{0,1\}Driver Attention Alert \{0,1\}|驾驶员注意力警示|g
s| \{0,1\}Forward Obstruction Warning \{0,1\}|前方障碍预警|g
s| \{0,1\}High Beam Control \{0,1\}|远光灯控制|g
s| \{0,1\}Lane Departure Warning System \{0,1\}|车道偏离预警系统|g
s| \{0,1\}Lane-keep Assist System \{0,1\}|车道保持辅助系统|g
s| \{0,1\}Mazda Radar Cruise Control \{0,1\}|雷达巡航控制|g
s| \{0,1\}Smart City Brake Support \{0,1\}|城市智能制动|g
s| \{0,1\}Smart Brake Support \{0,1\}|智能制动辅助|g
s| \{0,1\}Traffic Sign Recognition System \{0,1\}|交通标志识别系统|g
s| \{0,1\}Active Driving Display \{0,1\}|平视显示(HUD)|g
EOF

    # C. system: key-anchored value replacements
    cat > "$_p02_tmp/sys.sed" <<'EOF'
s|^\([[:space:]]*"DidYouSay"[[:space:]]*:[[:space:]]*"\)[^"]*"|\1你说的是："|
s|^\([[:space:]]*"EcoenergyApp"[[:space:]]*:[[:space:]]*"\)[^"]*"|\1油耗监测"|
s|^\([[:space:]]*"UseCommander"[[:space:]]*:[[:space:]]*"\)[^"]*"|\1请使用旋钮控制器"|
s|^\([[:space:]]*"WarnGuidanceApp"[[:space:]]*:[[:space:]]*"\)[^"]*"|\1预警提示"|
EOF

    # D. mobile911
    cat > "$_p02_tmp/m911.sed" <<'EOF'
s|^\([[:space:]]*"mobile911"[[:space:]]*:[[:space:]]*"\)[^"]*"|\1紧急呼叫"|
s|電話|电话|g
s|連接|连接|g
EOF

    # E. sysupdate: key-anchored ("Update" does not match "UpdatePackage"
    #    because the closing quote is part of the anchor)
    cat > "$_p02_tmp/sysupd.sed" <<'EOF'
s|^\([[:space:]]*"Noticeforupadate"[[:space:]]*:[[:space:]]*"\)[^"]*"|\1准备完成后屏幕将变黑，随后自动开始更新。"|
s|^\([[:space:]]*"PreparingtoUpdate"[[:space:]]*:[[:space:]]*"\)[^"]*"|\1正在准备更新"|
s|^\([[:space:]]*"Back"[[:space:]]*:[[:space:]]*"\)[^"]*"|\1返回"|
s|^\([[:space:]]*"Update"[[:space:]]*:[[:space:]]*"\)[^"]*"|\1更新"|
s|^\([[:space:]]*"UpdatePackage"[[:space:]]*:[[:space:]]*"\)[^"]*"|\1更新包"|
EOF
    return 0
}

# ──────────────────────────────────────────────────────────────
# Check (read-only)
# ──────────────────────────────────────────────────────────────
plugin_check() {
    if [ ! -f "$P02_FM_RES" ]; then
        nd2cn_log "FAIL: reference dict $P02_FM_RES not found"
        return 1
    fi
    if ! LC_ALL=C grep -q '^[[:space:]]*"rbds_genre_' "$P02_FM_RES"; then
        nd2cn_log "FAIL: no rbds_genre_* entries in $P02_FM_RES"
        return 1
    fi
    _p02_found=0
    for _p02_t in $P02_FILES; do
        if [ -f "$_p02_t" ]; then
            _p02_found=$((_p02_found + 1))
        else
            nd2cn_log "WARN: $_p02_t not found (will be skipped)"
        fi
    done
    if [ "$_p02_found" = "0" ]; then
        nd2cn_log "FAIL: none of the target dictionaries exist"
        return 1
    fi
    nd2cn_log "OK: reference dict + $_p02_found target dictionaries"
    return 0
}

# ──────────────────────────────────────────────────────────────
# Apply
# ──────────────────────────────────────────────────────────────
plugin_apply() {
    _p02_fail=0

    if [ ! -f "$P02_FM_RES" ]; then
        nd2cn_log "ERROR: reference dict $P02_FM_RES not found"
        return 1
    fi

    # Sed scripts are scratch data: build them on tmpfs, not on /data (flash).
    # ($$ is the installer's PID here, whose own work dir is nd2cn.$$)
    # Leftovers of an interrupted earlier run (older versions used /data):
    rm -rf "$ND2CN_DIR"/.p02.* "${TMPDIR:-/tmp}"/nd2cn-p02.*
    _p02_tmpdir="${TMPDIR:-/tmp}/nd2cn-p02.$$"
    if ! mkdir -p "$_p02_tmpdir"; then
        nd2cn_log "ERROR: cannot create $_p02_tmpdir"
        return 1
    fi
    if ! _p02_write_scripts "$_p02_tmpdir"; then
        nd2cn_log "ERROR: failed to build sed scripts"
        rm -rf "$_p02_tmpdir"
        return 1
    fi

    # ── A. fmradio (apps/ fallback copy) ──
    _p02_fix_file "$P02_FM_APPS" "$_p02_tmpdir/fm.sed" \
"流行樂
搖滾樂
爵士樂
國家/地區
紀錄片
類型
烽煙節目" \
'"Pop" : "流行乐"
"Rock" : "摇滚乐"
"Jazz" : "爵士乐"
"Country" : "乡村音乐"
"Documentary" : "纪录片"
"GenrePhoneIn" : "类型： 热线直播"' \
        "fmradio dict (rbds genres + simplified chars)" || _p02_fail=1

    # The rbds_genre_* set must now match the reference dict exactly.
    if [ -f "$P02_FM_APPS" ]; then
        _p02_rbds_pairs "$P02_FM_RES" > "$_p02_tmpdir/rbds.ref"
        _p02_rbds_pairs "$P02_FM_APPS" > "$_p02_tmpdir/rbds.cur"
        if cmp -s "$_p02_tmpdir/rbds.ref" "$_p02_tmpdir/rbds.cur"; then
            nd2cn_log "fmradio rbds_genre_*: $(wc -l < "$_p02_tmpdir/rbds.cur") entries match reference"
        else
            nd2cn_log "ERROR: fmradio rbds_genre_* entries do not match reference dict"
            _p02_fail=1
        fi
    fi

    # ── B. vehsettings ──
    _p02_fix_file "$P02_VEH" "$_p02_tmpdir/veh.sed" \
"Adaptive LED Headlights
Distance Recognition Support System
Driver Attention Alert
Forward Obstruction Warning
High Beam Control
Lane Departure Warning System
Lane-keep Assist System
Mazda Radar Cruise Control
Smart Brake Support
Smart City Brake Support
Traffic Sign Recognition System
Active Driving Display" \
'"AHBC" : "自适应LED大灯"
"DRSS" : "距离识别辅助系统"
"DriverAlert" : "驾驶员注意力警示"
"ForwardObstructionWarning" : "前方障碍预警"
"HighBeamControl" : "远光灯控制"
"LaneDepartureWarningSystem" : "车道偏离预警系统"
"LaneKeepAssistSystem" : "车道保持辅助系统"
"LASDefaultValues" : "您确定要将车道保持辅助系统设置恢复为默认值吗？"
"MRCC" : "雷达巡航控制"
"SmartBrakeSupport" : "智能制动辅助"
"SCBS" : "城市智能制动"
"TSR_System" : "交通标志识别系统"
"TSRReset" : "确定要将交通标志识别系统设置恢复为默认值？"
"HeadUpDisplay" : "平视显示(HUD)"
"HUDJ78AResetError" : "重置平视显示(HUD)设置时出现错误。 是否要重试？"' \
        "vehsettings dict (safety feature names)" || _p02_fail=1

    # ── C. system ──
    _p02_fix_file "$P02_SYS" "$_p02_tmpdir/sys.sed" \
'"DidYouSay" : "请选择："
[监测器]
命令程序
"WarnGuidanceApp" : "警告指导"' \
'"DidYouSay" : "你说的是："
"EcoenergyApp" : "油耗监测"
"UseCommander" : "请使用旋钮控制器"
"WarnGuidanceApp" : "预警提示"' \
        "system dict (mistranslations)" || _p02_fail=1

    # ── D. mobile911 ──
    _p02_fix_file "$P02_M911" "$_p02_tmpdir/m911.sed" \
"移动 110
電話
連接" \
'"mobile911" : "紧急呼叫"
"Connected" : "电话： 已连接至 911"
"Connecting" : "电话： 正在连接中"' \
        "mobile911 dict" || _p02_fail=1

    # ── E. sysupdate ──
    _p02_fix_file "$P02_SYSUPD" "$_p02_tmpdir/sysupd.sed" \
'"Back" : "Back"
"Update" : "Update"
"UpdatePackage" : "Update Package"
"PreparingtoUpdate" : "Preparing to Update."
black screen is displayed' \
'"Noticeforupadate" : "准备完成后屏幕将变黑，随后自动开始更新。"
"PreparingtoUpdate" : "正在准备更新"
"Back" : "返回"
"Update" : "更新"
"UpdatePackage" : "更新包"' \
        "sysupdate dict" || _p02_fail=1

    rm -rf "$_p02_tmpdir"

    if [ "$_p02_fail" != "0" ]; then
        nd2cn_log "finished with errors (re-run to complete)"
        return 1
    fi
    nd2cn_log "all dictionaries up to date"
    return 0
}

# ──────────────────────────────────────────────────────────────
# Remove: restore each dict from its pristine backup (atomically), then
# release the backup. No other plugin modifies these files, so the pristine
# copy is exactly the state before this plugin.
# ──────────────────────────────────────────────────────────────
plugin_remove() {
    _p02_fail=0
    for _p02_t in $P02_FILES; do
        nd2cn_restore_file "$_p02_t" "$PATCH_TAG"
        case $? in
            0) ;;
            2) nd2cn_log "$(basename "$_p02_t"): not patched (skip)" ;;
            *) _p02_fail=1 ;;
        esac
    done
    rm -rf "$ND2CN_DIR"/.p02.* "${TMPDIR:-/tmp}"/nd2cn-p02.*
    return $_p02_fail
}
