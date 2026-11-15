nd2cn optional plugins
======================

install.sh runs every *.sh file directly inside plugins/ (in filename
order). Files in THIS folder (plugins/optional/) are NOT run.

To enable an optional plugin, move (or copy) its .sh file up one level into
plugins/. To disable any plugin, delete it from plugins/ (or move it here).
Removing a file from the USB stick does not undo a plugin that is already
installed — use uninstall.sh for that:

  sh uninstall.sh                  remove everything
  sh uninstall.sh 11-ssh-access    remove one plugin

These were opt-in in nd2cn v1 (flag files) and stay opt-in:

  07-boot-speedup.sh      [high]          truncate looping boot logo videos   (was FAST_BOOT)
  10-touch-unlock.sh      [high]          touchscreen while driving           (was TOUCH_UNLOCK)
  11-ssh-access.sh        [medium]        key-only SSH; put keys in resources/ssh_keys/*.pub
  12-custom-eq.sh         [medium]        custom DSP profile; put it in resources/eq/*.xml
  18-wireless-carplay.sh  [experimental]  open WCP firewall ports             (was ENABLE_WCP)
  19-bt-audio-latency.sh  [experimental]  smaller BT A2DP buffer              (was REDUCE_BT_LATENCY)
  20-flac-check.sh        [low]           FLAC support diagnostic only        (was ENABLE_FLAC)
  21-track-dashboard.sh   [experimental]  Track Dash app (installs app/ into /data/nd2cn/app/)
                                           also sets "Allow File XMLHttpRequest=1"
                                           in opera.ini [User Prefs] (file:// XHR)

Plugins 11, 18, 19 and 21 need 00-boot-hook.sh (it is in plugins/ by default).

The v1 NMEA logger (ENABLE_NMEA) was dropped: it wrote to flash
continuously. A full uninstall still restores lds.xml on cars that had it.
Boot-time output of all plugins goes to /tmp/nd2cn/boot.log (RAM).

Dropped because they did not work on this firmware:
  08-disable-services  wrong process names; sm_svclauncher renames services
                       (S_ prefix), so killall never matched, and killing a
                       supervised service can reset the board
  15-simplified-pinyin the .cin dictionary is only used by the Traditional
                       Chinese keyboard, not by Simplified Chinese input
  17-wifi-security     jci-wifiap.sh generates its own hostapd config and
                       never read the file this plugin wrote
If one of them is still applied on a car, "sh uninstall.sh <name>" (or a
full uninstall) still removes it: the copy in /data/nd2cn/plugins/ is used.

Writing your own plugin: copy any plugin as a template. It must set
PLUGIN_NAME, PLUGIN_DESC, PLUGIN_RISK (low|medium|high|experimental) and
define plugin_check (read-only), plugin_apply (idempotent) and
plugin_remove. Declare dependencies with a comment line such as
"# requires: 00-boot-hook". Sourcing the file must have no side effects.
