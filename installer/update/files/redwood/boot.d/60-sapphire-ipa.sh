# tester bug 10: IPAs queued by the Android app (inbox after iOS volume), installed once SpringBoard is up (in the background)
# Uses enhanced script with TrollStore helper auto-detection, proper signing, uicache, and SpringBoard notification
setsid nohup /var/jb/bin/bash /redwood/bin/sapphire-ipa-install.sh >/dev/null 2>&1 &
