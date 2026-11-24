#!/system/bin/sh
# Transsion (TECNO CLA5 / silead) UDFPS fix for GSI ROMs.
#
# Problem 1: the silead HAL ignores the touch driver's finger-down/up notices
#   ("[silead_cust]E[_cust_finger_detect_dispatch] not handle it") until
#   Transsion's framework sends sendCommand(10,1) = "TP finger detect" on.
#   A GSI never sends it, so enrollment always times out and the lock screen
#   never reacts. We keep the HAL's internal gate byte in libsl_fp_impl.so
#   .bss (VA 0x6E4AC, i.e. r-xp mapping start + 0x674AC) set to 1 through
#   /proc/<pid>/mem.
#
# Problem 2: the panel area over the sensor must be lit. We take the backlight
#   to max, switch the panel to real HBM and set sys.hbm.force so the Xposed
#   module paints its white window.
#
# Problem 3: "Fps state: 1" arrives only after the finger went down, so waiting
#   for it via dumpsys left the sensor dark for the first frame after
#   screen-off ("works on the second try"). The Xposed module publishes the
#   keyguard state into its device-protected files dir; while the device is
#   locked we keep the circle + HBM armed even if the panel is off, so the
#   panel wakes up already lit and the very first capture has light.
#
# Problem 4: while the panel is really off it emits no light at all, so the
#   capture is black no matter what we pre-set. Stock wakes the display from
#   UdfpsController on the FOD touch; that pipeline is dead here, so we send
#   KEYCODE_WAKEUP ourselves (see the getevent loop below).
#
# NOTE: runs under busybox sh (Magisk), so use absolute /system/bin tools.

PATH=/system/bin:/system/xbin:/sbin
export PATH

HALNAME=fingerprint@2.1-service-mediatek
HBM=/sys/devices/platform/soc/14013000.dsi/lcm_hbm_state
BL=/sys/class/leds/lcd-backlight/brightness
BLMAX=/sys/class/leds/lcd-backlight/max_brightness
FPS=/proc/fingerprint_status
LOG=/data/local/tmp/udfps_fix.log

# Written by the Xposed module every ~250 ms: "1" = keyguard locked.
KG=/data/user_de/0/com.android.systemui/files/keyguard

# Fallback trigger when the module has not published the keyguard state yet:
# the focaltech driver emits EV_KEY 00c3 while tran_fingerprint_status is 1.
TOUCH=/data/local/tmp/.fod_touch

# The HAL waits up to 3 s inside silfp_cust_wait_ui_ready() for the kernel
# uevent "TRAN_FULL_HBM_EVENT=FULL_HBM_SET" ("waiting ui ..."). Transsion's
# display driver only fires it from its own HBM notifier, which never runs on
# a GSI: every auth stalled 3.02 s and normally missed the finger completely.
# The HAL's netlink thread simply strstr()s that string out of any uevent, so
# we broadcast it ourselves (uevent_fp: AF_NETLINK/KOBJECT_UEVENT, group 1,
# 12 messages x 15 ms to cover the race with the auth thread). Result: the
# wait drops from 3020 ms to ~30 ms and the capture happens while the finger
# is still on the sensor.
UEVT=/data/adb/modules/transsion_udfps/uevent_fp

# Transsion's focaltech driver only reports the FOD touch key (EV_KEY 0x00c3)
# while tran_fingerprint_status is 1. The write handler also programs touch IC
# register 0x02C5/0x02CF, so do it once per session, not in a tight loop.
fod_on() {
    echo 1 > $FPS 2>/dev/null && echo "$(date +%F_%T) fod mode on" >> $LOG
}

find_hal() {
    for d in /proc/[0-9]*; do
        e=$(readlink "$d/exe" 2>/dev/null)
        case "$e" in
            *"$HALNAME"*) echo "${d#/proc/}"; return 0;;
        esac
    done
    return 1
}

# wait for boot to settle before touching the HAL
i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ $i -lt 300 ]; do sleep 2; i=$((i+1)); done
sleep 8

echo "--- start $(date +%F_%T) ---" > $LOG
echo 0 > $TOUCH
fod_on

# Let the finger settle before the capture. After silfp_cust_wait_ui_ready()
# returns the HAL sleeps this property before grabbing the frame; the built-in
# 20 ms takes the picture while the finger is still landing (about a third of
# the taps ended in a mismatch), 80 ms gives a stable image and still feels
# instant (~200 ms from touch to accept).
setprop persist.log.tag.fp.delay.screenon 80
setprop persist.log.tag.fp.delay.screenoff 80
setprop persist.log.tag.fp.delay.screenblind 80

# zip does not keep the mode on every platform
chmod 755 "$UEVT" 2>/dev/null

# Warm up the "input" helper once: the very first FOD touch after a reboot
# otherwise pays the app_process startup cost and the display wakes too late
# for the first frames (they come out black).
input >/dev/null 2>&1

(
    getevent -lt /dev/input/event5 2>/dev/null | while read -r line; do
        case "$line" in
            *00c3*DOWN*)
                read -r up _ < /proc/uptime
                echo "${up%%.*}" > $TOUCH
                # With the panel fully off there is no light at all for the
                # sensor: every frame comes out black and auth fails. Android's
                # UdfpsController normally wakes the display on the FOD touch,
                # but this GSI has no working UDFPS pipeline. KEYCODE_WAKEUP
                # takes ~40 ms, so the panel is already lit when the HAL grabs
                # the frame 80 ms later.
                woke=0
                if [ "$(cat $KG 2>/dev/null)" != "0" ]; then
                    input keyevent 224 >/dev/null 2>&1 &
                    woke=1
                fi
                # unblock silfp_cust_wait_ui_ready()
                if [ -x "$UEVT" ]; then
                    if [ "$woke" = "1" ]; then
                        # give the panel a moment before the capture deadline
                        ( sleep 0.05; "$UEVT" >/dev/null 2>&1; r=$?; \
                          echo "$(date +%F_%T) uevent fired rc=$r" >> $LOG ) &
                    else
                        ( "$UEVT" >/dev/null 2>&1; r=$?; \
                          echo "$(date +%F_%T) uevent fired rc=$r" >> $LOG ) &
                    fi
                else
                    echo "$(date +%F_%T) uevent missing $UEVT" >> $LOG
                fi
                ;;
        esac
    done
) &

gate_pid=""
gate_addr=""
ui_on="-1"
prev_bl=""
tick=0
fps=0
kg=0
kg_known=0
last_err=""

while true; do
    tick=$((tick+1))

    # ---- 1) keep the HAL TP-finger-detect gate enabled ----
    # /proc scan + /proc/pid/mem read are not free: do it every 2 s, while the
    # light decision below runs every 100 ms.
    if [ $((tick % 20)) -eq 0 ]; then
    p=$(find_hal)
    if [ -n "$p" ] && [ "$p" != "$gate_pid" ]; then
        l=$(grep 'libsl_fp_impl.so' /proc/$p/maps 2>/dev/null | grep 'r-xp' | head -n 1)
        if [ -n "$l" ]; then
            s=${l%%-*}
            gate_addr=$(awk -v s=$s 'function h2d(x,  i,d){d=0;for(i=1;i<=length(x);i++){d=d*16+index("0123456789abcdef",tolower(substr(x,i,1)))-1}return d} BEGIN{printf "%.0f",h2d(s)+423084}')
            gate_pid=$p
            echo "$(date +%F_%T) gate pid=$p addr=$gate_addr" >> $LOG
        else
            if [ "$last_err" != "maps-$p" ]; then
                echo "$(date +%F_%T) hal pid=$p maps unreadable, retrying" >> $LOG
                last_err="maps-$p"
            fi
        fi
    fi

    if [ -n "$gate_addr" ] && [ -n "$p" ] && [ "$p" = "$gate_pid" ]; then
        c=$(dd if=/proc/$p/mem bs=1 skip=$gate_addr count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
        if [ "$c" != "01" ]; then
            printf '\1' | dd of=/proc/$p/mem bs=1 seek=$gate_addr conv=notrunc 2>/dev/null
            c2=$(dd if=/proc/$p/mem bs=1 skip=$gate_addr count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
            echo "$(date +%F_%T) gate set pid=$p was=$c now=$c2" >> $LOG
        fi
    else
        gate_pid=""
        gate_addr=""
    fi
    fi

    # ---- 2) decide whether the sensor area must be lit ----
    # keyguard locked  -> keep it armed even with the panel off, so the first
    #                     frame after wake-up is already illuminated
    # keyguard unlocked-> never: the glyph/white disc exist only on the lock
    #                     screen (touching the sensor after unlock must not
    #                     light anything up)
    # no keyguard file -> fall back to the touch heuristic below
    read -r kg < $KG 2>/dev/null
    case "$kg" in
        1) kg_known=1;;
        0) kg_known=1;;
        *) kg=0; kg_known=0;;
    esac

    read -r up _ < /proc/uptime
    now=${up%%.*}
    last=0
    read -r last < $TOUCH 2>/dev/null
    case "$last" in ''|*[!0-9]*) last=0;; esac
    age=$((now - last))

    want=0
    if [ "$kg" = "1" ]; then
        want=1
    elif [ "$kg_known" = "0" ] && [ $age -le 4 ]; then
        # module not publishing yet: only react to a touch on a dark panel
        bl=$(cat $BL 2>/dev/null)
        if [ "$bl" = "0" ]; then
            want=1
        fi
    fi

    if [ "$want" != "$ui_on" ]; then
        ui_on=$want
        if [ "$want" = "1" ]; then
            # Only remember/boost a backlight that is actually on: while the
            # panel is off BL is 0, and restoring that later blacks the screen
            # right when the user unlocks (looks like a SystemUI crash).
            bl=$(cat $BL 2>/dev/null)
            m=$(cat $BLMAX 2>/dev/null)
            if [ "$bl" != "0" ] && [ -n "$bl" ]; then
                prev_bl=$bl
                [ -n "$m" ] && echo "$m" > $BL
            else
                prev_bl=""
            fi
            echo 1 > $HBM
            setprop sys.hbm.force 1
            fod_on
            echo "$(date +%F_%T) fp ui on (prev_bl=$prev_bl bl=$bl age=$age fps=$fps kg=$kg)" >> $LOG
        else
            echo 0 > $HBM
            setprop sys.hbm.force 0
            bl=$(cat $BL 2>/dev/null)
            if [ -n "$prev_bl" ] && [ "$bl" != "0" ]; then
                echo "$prev_bl" > $BL 2>/dev/null
            fi
            echo "$(date +%F_%T) fp ui off (restore_bl=$prev_bl bl=$bl age=$age fps=$fps kg=$kg)" >> $LOG
        fi
    fi

    # ---- heartbeat ----
    if [ $((tick % 600)) -eq 0 ]; then
        echo "$(date +%F_%T) alive pid=$p gate=$c ui=$ui_on kg=$kg age=$age fps=$fps" >> $LOG
    fi

    sleep 0.1
done
