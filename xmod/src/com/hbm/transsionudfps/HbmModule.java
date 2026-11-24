
package com.hbm.transsionudfps;

import android.content.Context;
import android.content.res.Resources;
import android.app.KeyguardManager;
import android.hardware.fingerprint.FingerprintManager;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Point;
import android.graphics.PorterDuff;
import android.graphics.Rect;
import android.graphics.RectF;
import android.graphics.drawable.Drawable;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.provider.Settings;
import android.util.Log;
import android.view.Gravity;
import android.view.View;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.ImageView;

import java.io.File;
import java.io.FileOutputStream;
import java.lang.reflect.Method;

import de.robv.android.xposed.IXposedHookLoadPackage;
import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;
import de.robv.android.xposed.callbacks.XC_LoadPackage.LoadPackageParam;

public class HbmModule implements IXposedHookLoadPackage {

    private static final String TAG = "TranshitHBM";

    private static final String PROP_ENABLED = "persist.sys.phh.transsion_udfps_hbm";
    private static final String PROP_FORCE = "sys.hbm.force";
    private static final String PROP_MODE = "persist.sys.phh.udfps.hbm_mode";
    private static final String PROP_BAND = "persist.sys.phh.udfps.hbm_band";
    private static final String PROP_X = "persist.sys.phh.udfps.hbm_x";
    private static final String PROP_Y = "persist.sys.phh.udfps.hbm_y";
    private static final String PROP_RADIUS = "persist.sys.phh.udfps.hbm_radius";
    private static final String PROP_ICON = "persist.sys.phh.udfps.hbm_icon";

    private static final String TITLE = "TranshitHBMController";

    private static final String[] ICON_PACKAGES = {
            "org.evolution.udfps.icons",
            "com.evolution.udfps.icons",
            "org.evolutionx.udfps.icons",
            "com.evolutionx.udfps.icons",
            "org.evolution.udfps",
            "org.evolutionx.resources",
            "org.evolution.udfps.resources",
            "com.android.systemui"
    };
    private static final String ICON_ARRAY = "udfps_icons";
    private static final String ICON_SETTING = "udfps_icon";
    private static final String[] ICON_NAMES_FALLBACK = {
            "udfps_icon",
            "udfps_icon_default",
            "ic_udfps_icon",
            "udfps_fingerprint",
            "ic_udfps_fingerprint",
            "ic_fingerprint",
            "fingerprint_udfps",
            "ic_fingerprint_udfps",
            "udfps_fingerprint_icon"
    };

    private static final String KG_FILE = "keyguard";

    private static final int TYPE_PRIMARY = 0x7ea; // TYPE_DISPLAY_OVERLAY (2026)
    private static final int TYPE_FALLBACK = 0x7e8; // TYPE_NAVIGATION_BAR_PANEL (2024)
    private static final int FLAGS = WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
            | WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL
            | WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
            | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN
            | WindowManager.LayoutParams.FLAG_LAYOUT_INSET_DECOR
            | WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED
            | WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED;
    private static final int FORMAT_OPAQUE = -1;
    private static final int FORMAT_TRANSLUCENT = -3;

    private static final long HIDE_DELAY_MS = 150;
    private static final long[] ADD_RETRY_MS = { 30, 80, 200 };

    private static final int COLOR_GLYPH_IDLE = 0xFFB8B8B8;   /* grey */
    private static final int COLOR_GLYPH_TOUCH = 0xFF00E676;  /* green */
    private static final int ALPHA_GLYPH_IDLE = 110;
    private static final int ALPHA_GLYPH_TOUCH = 200;

    private static Handler sHandler;
    private static final Object LOCK = new Object();

    private static volatile Context sCtx;
    private static View sView;
    private static FrameLayout sRoot;
    private static volatile int sIconIndex = -1;
    private static volatile boolean sIconMissing;
    private static WindowManager sWm;
    private static volatile boolean sAuthRequested;
    private static volatile boolean sAppAuthRequested;
    private static volatile boolean sLocked;
    private static volatile boolean sKgKnown;
    private static volatile boolean sTouching;
    private static volatile boolean sTouchingVisualApplied;
    private static volatile boolean sVisualInitialised;
    private static volatile long sLastScreenOnAt;
    private static volatile long sAuthSetAt;
    private static Runnable sPendingHide;
    private static int sAddRetry;

    private static final XC_MethodHook DO_NOTHING = new XC_MethodHook() {
        @Override
        protected void beforeHookedMethod(MethodHookParam param) {
            param.setResult(null);
        }
    };

    @Override
    public void handleLoadPackage(LoadPackageParam lp) {
        if (!"com.android.systemui".equals(lp.packageName)) return;
        if (lp.processName != null && lp.processName.indexOf(':') >= 0) return;
        try {
            handle(lp);
        } catch (Throwable t) {
            log("init failed: " + t);
        }
    }

    private static void handle(LoadPackageParam lp) {
        sCtx = appContext();
        hookApplicationCreated();
        suppressSystemUiBrightnessChanges(lp);
        suppressSystemUiWhiteCircle(lp);
        hookUdfpsController(lp);
        hookEnrollmentUi(lp);
        hookFingerprintAuth(lp);
        startForceWatcher();
        startKeyguardWatcher();
        log("hooks installed on " + lp.processName + " ctx=" + (sCtx != null));
    }

    private static void runOnMainSync(Runnable r) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            r.run();
        } else {
            handler().post(r);
        }
    }

    private static Class<?> findClass(String className, ClassLoader classLoader) {
        try {
            return XposedHelpers.findClass(className, classLoader);
        } catch (Throwable t) {
            return null;
        }
    }

    /* ------------------------------------------------------------------ */
    /* Part 1: Brightness & White Circle Suppression                       */
    /* ------------------------------------------------------------------ */

    /**
     * Intentionally does not intercept brightness, HBM, sysfs or SystemProperties.
     * The fingerprint HAL/SystemUI must retain control of sensor illumination.
     */
    private static void suppressSystemUiBrightnessChanges(LoadPackageParam lp) {
        log("brightness/HBM hooks disabled: keeping stock sensor illumination");
    }

    /**
     * Avoid hiding the UDFPS root/touch surface: doing so can break the sensor UI.
     *
     * Only a separately attached view whose own class name explicitly identifies it
     * as an animation view is made transparent. The UdfpsView, SurfaceView,
     * illumination callbacks and drawing lifecycle are left untouched.
     *
     * Note: some vendor builds draw the ring directly inside UdfpsView. In that
     * case this conservative hook deliberately leaves it visible; hiding the
     * root view blindly is not safe because the same view may own touch/illumination.
     */
    private static void suppressSystemUiWhiteCircle(LoadPackageParam lp) {
        try {
            Class<?> wmImpl = findClass("android.view.WindowManagerImpl", lp.classLoader);
            if (wmImpl == null) {
                log("white-circle filter skipped: WindowManagerImpl not found");
                return;
            }

            XC_MethodHook animationViewFilter = new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    if (param.args == null || param.args.length < 2
                            || !(param.args[0] instanceof View)
                            || !(param.args[1] instanceof WindowManager.LayoutParams)) {
                        return;
                    }

                    View view = (View) param.args[0];
                    WindowManager.LayoutParams params =
                            (WindowManager.LayoutParams) param.args[1];

                    CharSequence titleValue = params.getTitle();
                    String title = titleValue == null ? "" :
                            titleValue.toString().toLowerCase(java.util.Locale.ROOT);
                    String className = view.getClass().getName()
                            .toLowerCase(java.util.Locale.ROOT);

                    // Do not touch our own overlay, the UDFPS root, or a SurfaceView.
                    if (TITLE.equals(title)
                            || className.contains("udfpsview")
                            || className.contains("surfaceview")
                            || className.contains("udfpssurface")) {
                        return;
                    }

                    // Restrict the change to a separately hosted animation view.
                    if (className.contains("udfpsanimationview")
                            || className.contains("udfpsanimation")
                            || title.contains("udfpsanimation")) {
                        view.setAlpha(0.0f);
                        log("made separate UDFPS animation view transparent: " + className);
                    }
                }
            };

            XposedBridge.hookAllMethods(wmImpl, "addView", animationViewFilter);
            XposedBridge.hookAllMethods(wmImpl, "updateViewLayout", animationViewFilter);
            log("conservative UDFPS animation filter installed");
        } catch (Throwable t) {
            log("suppressSystemUiWhiteCircle error: " + t);
        }
    }

    /* ------------------------------------------------------------------ */
    /* Part 2: window management & lockscreen enrollment check             */
    /* ------------------------------------------------------------------ */

    private static Context appContext() {
        try {
            Class<?> at = Class.forName("android.app.ActivityThread");
            Method m = at.getMethod("currentApplication");
            Object app = m.invoke(null);
            if (app instanceof Context) return (Context) app;
        } catch (Throwable ignored) {}
        try {
            Class<?> helper = Class.forName("de.robv.android.xposed.AndroidAppHelper");
            Method m = helper.getMethod("currentApplication");
            Object app = m.invoke(null);
            if (app instanceof Context) return (Context) app;
        } catch (Throwable ignored) {}
        return null;
    }

    private static void hookApplicationCreated() {
        try {
            XposedHelpers.findAndHookMethod(android.app.Application.class, "onCreate",
                    new XC_MethodHook() {
                        @Override
                        protected void afterHookedMethod(MethodHookParam param) {
                            if (param.thisObject instanceof Context) {
                                sCtx = (Context) param.thisObject;
                                log("application context captured");
                            }
                        }
                    });
        } catch (Throwable t) {
            log("app hook skipped: " + t);
        }
    }

    private static boolean isScreenOn(Context ctx) {
        try {
            PowerManager pm = (PowerManager) ctx.getSystemService(Context.POWER_SERVICE);
            return pm != null && pm.isInteractive();
        } catch (Throwable t) {
            return true;
        }
    }

    private static boolean hasEnrolledFingerprints(Context ctx) {
        try {
            if (ctx == null) return true;
            FingerprintManager fm = (FingerprintManager) ctx.getSystemService(Context.FINGERPRINT_SERVICE);
            if (fm != null) {
                return fm.hasEnrolledFingerprints();
            }
        } catch (Throwable t) {
            log("hasEnrolledFingerprints check error: " + t);
        }
        return true;
    }

    private static boolean isKeyguardLocked(Context ctx) {
        try {
            KeyguardManager km = (KeyguardManager) ctx.getSystemService(Context.KEYGUARD_SERVICE);
            return km != null && km.isKeyguardLocked();
        } catch (Throwable t) {
            return false;
        }
    }

    /**
     * Should the window exist right now?
     */
    private static boolean shouldShowNow() {
        Context ctx = sCtx;
        if (ctx == null) return false;
        if (!isScreenOn(ctx)) return false;

        /* Lock screen: show glyph whenever keyguard is locked */
        if (isKeyguardLocked(ctx)) {
            return hasEnrolledFingerprints(ctx);
        }

        /* Fingerprint authentication or enrollment or BiometricPrompt (Google Play) active */
        if (sAuthRequested || sAppAuthRequested) {
            return true;
        }

        boolean force = getBool(PROP_FORCE, false);

        return force || sTouching;
    }

    /** Is the "touch" visual required? */
    private static boolean isTouchVisual() {
        if (sAppAuthRequested) return true;
        if (sTouching) return true;
        if (getBool(PROP_FORCE, false)) return true;
        return false;
    }

    private static void startForceWatcher() {
        Thread t = new Thread(new Runnable() {
            @Override
            public void run() {
                boolean last = false;
                int tick = 0;
                boolean lastTouch = false;
                while (true) {
                    tick++;
                    boolean now;
                    try { now = shouldShowNow(); } catch (Throwable t) { now = false; }
                    if (now != last) {
                        last = now;
                        if (now) {
                            runOnMainSync(new Runnable() {
                                @Override public void run() { requestShow("watch"); }
                            });
                        } else {
                            runOnMainSync(new Runnable() {
                                @Override public void run() { requestHide("watch"); }
                            });
                        }
                    }
                    boolean touch = isTouchVisual();
                    if (now && touch != lastTouch) {
                        lastTouch = touch;
                        final boolean t2 = touch;
                        runOnMainSync(new Runnable() {
                            @Override public void run() { repaintIcon(t2); }
                        });
                    }
                    if (now) {
                        final Context c = sCtx;
                        final FrameLayout root = sRoot;
                        if (c != null && root != null && (tick % 6) == 0) {
                            final int idx = readIconIndex(c);
                            boolean changed = idx >= 0 && idx != sIconIndex;
                            boolean retry = sIconMissing && iconPackInstalled(c);
                            if (changed || retry) {
                                runOnMainSync(new Runnable() {
                                    @Override
                                    public void run() {
                                        Context cc = sCtx;
                                        FrameLayout rr = sRoot;
                                        if (cc != null && rr != null) {
                                            repaintIcon(isTouchVisual());
                                            log("udfps icon redraw -> " + idx);
                                        }
                                    }
                                });
                            }
                        }
                    }
                    try { Thread.sleep(50); } catch (InterruptedException e) { return; }
                }
            }
        }, "TranshitHBM-watch");
        t.setDaemon(true);
        t.start();
    }

    private static void startKeyguardWatcher() {
        Thread t = new Thread(new Runnable() {
            @Override
            public void run() {
                String last = null;
                boolean lastScreenOn = false;
                while (true) {
                    try {
                        Context ctx = sCtx;
                        if (ctx != null) {
                            boolean screenOn = isScreenOn(ctx);
                            if (screenOn && !lastScreenOn) {
                                sLastScreenOnAt = System.currentTimeMillis();
                                log("screen turned ON from sleep at " + sLastScreenOnAt);
                                sTouching = false;
                                runOnMainSync(new Runnable() {
                                    @Override public void run() {
                                        if (shouldShowNow()) {
                                            requestShow("wake-from-sleep");
                                        }
                                    }
                                });
                            }
                            lastScreenOn = screenOn;

                            boolean locked = isKeyguardLocked(ctx);
                            if (!sKgKnown || locked != sLocked) {
                                sLocked = locked;
                                sKgKnown = true;
                                if (!locked && !sAppAuthRequested) {
                                    runOnMainSync(new Runnable() {
                                        @Override public void run() { requestHide("unlock"); }
                                    });
                                } else if (locked && screenOn) {
                                    runOnMainSync(new Runnable() {
                                        @Override public void run() { requestShow("lockscreen"); }
                                    });
                                }
                            }
                            String v = locked ? "1" : "0";
                            if (!v.equals(last) && writeKeyguard(ctx, v)) {
                                last = v;
                                log("keyguard " + v);
                            }
                        }
                    } catch (Throwable ignored) {}
                    try { Thread.sleep(40); } catch (InterruptedException e) { return; }
                }
            }
        }, "TranshitHBM-kg");
        t.setDaemon(true);
        t.start();
    }

    private static boolean writeKeyguard(Context ctx, String v) {
        Context storage = ctx;
        try { storage = ctx.createDeviceProtectedStorageContext(); } catch (Throwable ignored) {}
        try {
            FileOutputStream fos = new FileOutputStream(new File(storage.getFilesDir(), KG_FILE));
            fos.write(v.getBytes("UTF-8"));
            fos.close();
            return true;
        } catch (Throwable t) {
            log("keyguard write failed: " + t);
            return false;
        }
    }

    private static void requestShow(String why) {
        synchronized (LOCK) {
            if (sPendingHide != null) {
                handler().removeCallbacks(sPendingHide);
                sPendingHide = null;
            }
            sAddRetry = 0;
            showWindowLocked(why);
        }
    }

    private static void requestHide(String why) {
        synchronized (LOCK) {
            if (sPendingHide != null) handler().removeCallbacks(sPendingHide);
            final String reason = why;
            sPendingHide = new Runnable() {
                @Override
                public void run() {
                    synchronized (LOCK) {
                        sPendingHide = null;
                        boolean stillNeeded;
                        try { stillNeeded = shouldShowNow(); }
                        catch (Throwable t) { stillNeeded = false; }
                        if (stillNeeded) {
                            log("hide(" + reason + ") cancelled: still needed");
                            return;
                        }
                        hideWindowLocked(reason);
                    }
                }
            };
            handler().postDelayed(sPendingHide, HIDE_DELAY_MS);
        }
    }

    private static int[] getSensorBounds(Context ctx) {
        int w = 1080, h = 2400;
        try {
            WindowManager wm = (WindowManager) ctx.getSystemService(Context.WINDOW_SERVICE);
            if (wm != null) {
                Point size = new Point();
                wm.getDefaultDisplay().getRealSize(size);
                if (size.x > 0 && size.y > 0) {
                    w = size.x;
                    h = size.y;
                }
            }
        } catch (Throwable ignored) {}

        int defaultCx = w / 2;
        // 90.8% down the screen height corresponds to Y=2179 on 2400h display
        int defaultCy = (int) (h * 0.908f);
        int defaultRadius = Math.max(80, (int) (w * 0.11f));

        int cx = getInt(PROP_X, defaultCx);
        int cy = getInt(PROP_Y, defaultCy);
        int radius = getInt(PROP_RADIUS, defaultRadius);

        return new int[] { cx, cy, radius };
    }

    private static WindowManager.LayoutParams createLayoutParams(Context ctx, int windowType, boolean circle) {
        int[] bounds = getSensorBounds(ctx);
        int cx = bounds[0];
        int cy = bounds[1];
        int radius = bounds[2];

        WindowManager.LayoutParams lp;
        if (circle) {
            lp = new WindowManager.LayoutParams(
                    2 * radius, 2 * radius, cx - radius, cy - radius, windowType, FLAGS, FORMAT_TRANSLUCENT);
            lp.gravity = Gravity.TOP | Gravity.LEFT;
        } else {
            int h = getInt(PROP_BAND, 520);
            lp = new WindowManager.LayoutParams(
                    WindowManager.LayoutParams.MATCH_PARENT, h, 0, 0,
                    windowType, FLAGS, FORMAT_TRANSLUCENT);
            lp.gravity = Gravity.BOTTOM | Gravity.LEFT;
        }
        lp.setTitle(TITLE);
        lp.screenBrightness = WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE;
        try { lp.setFitInsetsTypes(0); } catch (Throwable ignored) {}
        try {
            lp.layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS;
        } catch (Throwable ignored) {}
        return lp;
    }

    private static void showWindowLocked(String why) {
        if (!getBool(PROP_ENABLED, true)) {
            log("disabled by " + PROP_ENABLED);
            return;
        }
        if (!shouldShowNow()) {
            log("showWindow(" + why + ") skipped: not needed now");
            return;
        }
        if (sView != null) {
            if (!sVisualInitialised || sTouchingVisualApplied != isTouchVisual()) {
                repaintIcon(isTouchVisual());
            }
            return;
        }
        Context ctx = sCtx;
        if (ctx == null) { sCtx = appContext(); ctx = sCtx; }
        if (ctx == null) { log("showWindow: no context"); return; }
        WindowManager wm = (WindowManager) ctx.getSystemService(Context.WINDOW_SERVICE);
        if (wm == null) { log("showWindow: no WindowManager"); return; }

        String mode = getStr(PROP_MODE, "circle");
        final boolean circle = "circle".equals(mode);
        final int radius = getSensorBounds(ctx)[2];

        WindowManager.LayoutParams lp = createLayoutParams(ctx, TYPE_PRIMARY, circle);

        View v;
        FrameLayout fl = null;
        final boolean touch = isTouchVisual();
        if (circle) {
            fl = new FrameLayout(ctx);
            applyIcon(ctx, fl, radius, touch);
            v = fl;
        } else {
            v = new View(ctx);
            v.setBackgroundColor(0x00000000);
        }

        try {
            try {
                wm.addView(v, lp);
            } catch (Throwable t1) {
                log("addView with TYPE_PRIMARY failed: " + t1 + ", fallback to TYPE_FALLBACK");
                lp = createLayoutParams(ctx, TYPE_FALLBACK, circle);
                wm.addView(v, lp);
            }
            sView = v;
            sWm = wm;
            sRoot = fl;
            sAddRetry = 0;
            sTouchingVisualApplied = touch;
            sVisualInitialised = true;
            boostBacklight();
            log("HBM window added (" + why + ", " + mode + ", touch=" + touch + ") "
                    + lp.width + "x" + lp.height + " at " + lp.x + "," + lp.y);
        } catch (Throwable t) {
            if (sAddRetry < ADD_RETRY_MS.length) {
                long delay = ADD_RETRY_MS[sAddRetry++];
                log("addView failed (" + t + "), retry " + sAddRetry + " in " + delay + "ms");
                handler().postDelayed(new Runnable() {
                    @Override
                    public void run() {
                        synchronized (LOCK) {
                            if (sView == null && sPendingHide == null) {
                                showWindowLocked("retry");
                            }
                        }
                    }
                }, delay);
            } else {
                log("addView failed permanently: " + t);
            }
        }
    }

    private static void hideWindowLocked(String why) {
        View v = sView;
        WindowManager wm = sWm;
        sView = null;
        sWm = null;
        sRoot = null;
        sIconIndex = -1;
        sIconMissing = false;
        sAddRetry = 0;
        sTouchingVisualApplied = false;
        sVisualInitialised = false;
        if (sPendingHide != null) {
            handler().removeCallbacks(sPendingHide);
            sPendingHide = null;
        }
        restoreBacklight();
        if (v == null || wm == null) return;
        try {
            wm.removeViewImmediate(v);
            log("HBM window removed (" + why + ")");
        } catch (Throwable t) {
            try {
                wm.removeView(v);
                log("HBM window removed (" + why + ", deferred)");
            } catch (Throwable t2) {
                log("removeView failed: " + t2);
            }
        }
    }

    /** Re-render the glyph in the requested visual state without recreating the window. */
    private static void repaintIcon(boolean touching) {
        Context ctx = sCtx;
        FrameLayout fl = sRoot;
        if (ctx == null || fl == null) {
            log("repaintIcon: no root (touch=" + touching + ")");
            return;
        }
        applyIcon(ctx, fl, getSensorBounds(ctx)[2], touching);
        fl.postInvalidate();
        sTouchingVisualApplied = touching;
        sVisualInitialised = true;
        if (touching) {
            boostBacklight();
        } else {
            restoreBacklight();
        }
        log("glyph repainted touch=" + touching);
    }

    /* ------------------------------------------------------------------ */
    /* Evolution OS Icon loading & Fallback Fingerprint Icon              */
    /* ------------------------------------------------------------------ */

    private static Drawable loadUdfpsIcon(Context ctx, boolean touching) {
        int idx = readIconIndex(ctx);
        for (String pkg : ICON_PACKAGES) {
            try {
                Resources res = ctx.getPackageManager().getResourcesForApplication(pkg);
                if (res == null) continue;

                int arrayId = res.getIdentifier(ICON_ARRAY, "array", pkg);
                if (arrayId != 0) {
                    String[] names = res.getStringArray(arrayId);
                    if (idx >= 0 && idx < names.length) {
                        int drawableId = res.getIdentifier(names[idx], "drawable", pkg);
                        if (drawableId != 0) {
                            Drawable d = res.getDrawable(drawableId, null);
                            if (d != null) {
                                d = d.mutate();
                                d.setColorFilter(touching ? COLOR_GLYPH_TOUCH : COLOR_GLYPH_IDLE, PorterDuff.Mode.SRC_IN);
                                d.setAlpha(touching ? ALPHA_GLYPH_TOUCH : ALPHA_GLYPH_IDLE);
                                log("udfps icon loaded from " + pkg + ": " + names[idx]);
                                return d;
                            }
                        }
                    }
                }

                for (String name : ICON_NAMES_FALLBACK) {
                    int drawableId = res.getIdentifier(name, "drawable", pkg);
                    if (drawableId != 0) {
                        Drawable d = res.getDrawable(drawableId, null);
                        if (d != null) {
                            d = d.mutate();
                            d.setColorFilter(touching ? COLOR_GLYPH_TOUCH : COLOR_GLYPH_IDLE, PorterDuff.Mode.SRC_IN);
                            d.setAlpha(touching ? ALPHA_GLYPH_TOUCH : ALPHA_GLYPH_IDLE);
                            log("udfps icon loaded from " + pkg + ": " + name);
                            return d;
                        }
                    }
                }
            } catch (Throwable ignored) {}
        }
        return null;
    }

    private static Bitmap createFallbackFingerprintIcon(int size, boolean touching) {
        try {
            Bitmap bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888);
            Canvas canvas = new Canvas(bitmap);
            float center = size / 2f;
            float baseRadius = size * 0.4f;

            Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeWidth(Math.max(3f, size * 0.045f));
            paint.setStrokeCap(Paint.Cap.ROUND);
            paint.setColor(touching ? COLOR_GLYPH_TOUCH : COLOR_GLYPH_IDLE);
            paint.setAlpha(touching ? ALPHA_GLYPH_TOUCH : ALPHA_GLYPH_IDLE);

            for (int i = 1; i <= 5; i++) {
                float r = baseRadius * (i / 5f);
                RectF oval = new RectF(center - r, center - r, center + r, center + r);
                canvas.drawArc(oval, 205 + (i * 5), 130 - (i * 8), false, paint);
            }
            RectF core = new RectF(center - baseRadius * 0.16f,
                    center - baseRadius * 0.28f,
                    center + baseRadius * 0.16f,
                    center + baseRadius * 0.28f);
            canvas.drawArc(core, 205, 130, false, paint);

            return bitmap;
        } catch (Throwable t) {
            return null;
        }
    }

    private static int readIconIndex(Context ctx) {
        try {
            return Settings.System.getInt(ctx.getContentResolver(), ICON_SETTING, 0);
        } catch (Throwable t) { return -1; }
    }

    private static boolean iconPackInstalled(Context ctx) {
        for (String pkg : ICON_PACKAGES) {
            try {
                ctx.getPackageManager().getPackageInfo(pkg, 0);
                return true;
            } catch (Throwable ignored) {}
        }
        return false;
    }

    private static Bitmap fitToBitmap(Drawable icon, int size) {
        if (icon == null || size <= 0) return null;
        try {
            final int n = 256;
            Bitmap src = Bitmap.createBitmap(n, n, Bitmap.Config.ARGB_8888);
            Canvas c = new Canvas(src);
            icon.setBounds(0, 0, n, n);
            icon.draw(c);

            int l = n, t = n, r = -1, b = -1;
            int[] row = new int[n];
            for (int y = 0; y < n; y++) {
                src.getPixels(row, 0, n, 0, y, n, 1);
                for (int x = 0; x < n; x++) {
                    if (((row[x] >>> 24) & 0xFF) > 8) {
                        if (x < l) l = x;
                        if (x > r) r = x;
                        if (y < t) t = y;
                        if (y > b) b = y;
                    }
                }
            }
            if (r < l || b < t) {
                src.recycle();
                return null;
            }
            int iw = r - l + 1;
            int ih = b - t + 1;
            Bitmap ink = Bitmap.createBitmap(src, l, t, iw, ih);
            Bitmap out = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888);
            Canvas oc = new Canvas(out);
            float box = size * 0.98f;
            float scale = Math.min(box / iw, box / ih);
            int w = Math.max(1, Math.round(iw * scale));
            int h = Math.max(1, Math.round(ih * scale));
            int dx = (size - w) / 2;
            int dy = (size - h) / 2;
            Paint p = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.FILTER_BITMAP_FLAG);
            oc.drawBitmap(ink, null, new Rect(dx, dy, dx + w, dy + h), p);
            ink.recycle();
            src.recycle();
            return out;
        } catch (Throwable t) {
            return null;
        }
    }

    /**
     * The background of the UDFPS window is kept completely transparent.
     * Evolution OS fingerprint icon is rendered as a neat small icon centered above everything.
     */
    private static void applyIcon(Context ctx, FrameLayout fl, int radius, boolean touching) {
        fl.removeAllViews();
        fl.setBackgroundColor(0x00000000);
        sIconMissing = false;

        double scale = getDoubleProp("persist.sys.phh.udfps.icon_scale", 1.15);
        final int iconSize = Math.max(32, (int) (radius * scale));

        Bitmap bitmap = null;

        if (getBool(PROP_ICON, true)) {
            Drawable icon = loadUdfpsIcon(ctx, touching);
            if (icon != null) {
                bitmap = fitToBitmap(icon, iconSize);
            } else if (!iconPackInstalled(ctx)) {
                log("udfps icon: no pack installed");
            } else {
                sIconMissing = true;
                log("udfps icon: glyph unavailable (will retry)");
            }
        }

        if (bitmap == null) {
            bitmap = createFallbackFingerprintIcon(iconSize, touching);
        }

        if (bitmap != null) {
            ImageView iv = new ImageView(ctx);
            FrameLayout.LayoutParams ilp = new FrameLayout.LayoutParams(iconSize, iconSize);
            ilp.gravity = Gravity.CENTER;
            iv.setLayoutParams(ilp);
            iv.setScaleType(ImageView.ScaleType.FIT_CENTER);
            iv.setImageBitmap(bitmap);
            fl.addView(iv);
        }

        sIconIndex = readIconIndex(ctx);
    }

    /* ------------------------------------------------------------------ */
    /* Backlight sysfs                                                     */
    /* ------------------------------------------------------------------ */

    private static void boostBacklight() {
        /* No-op: do not alter display backlight brightness when fingerprint is shown/touched */
    }

    private static void restoreBacklight() {
        /* No-op: do not alter display backlight brightness when fingerprint is shown/touched */
    }

    /* ------------------------------------------------------------------ */
    /* Part 3: legacy UdfpsController hooks                                */
    /* ------------------------------------------------------------------ */

    private static void hookUdfpsController(LoadPackageParam lp) {
        try {
            Class<?> controller = findClass(
                    "com.android.systemui.biometrics.UdfpsController", lp.classLoader);
            if (controller == null) return;

            XposedBridge.hookAllMethods(controller, "showUdfpsOverlay", new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    log("showUdfpsOverlay()");
                    markAuthRequested("overlay");
                    runOnMainSync(new Runnable() {
                        @Override public void run() { requestShow("udfps"); }
                    });
                }
            });

            XposedBridge.hookAllMethods(controller, "hideUdfpsOverlay", new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    runOnMainSync(new Runnable() {
                        @Override
                        public void run() {
                            if (sAppAuthRequested || isKeyguardLocked(sCtx)) {
                                log("hideUdfpsOverlay ignored: keyguard or app auth active");
                                return;
                            }
                            sTouching = false;
                            sAuthRequested = false;
                            requestHide("udfps");
                        }
                    });
                }
            });

            XC_MethodHook fingerDownHook = new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    log("onFingerDown/PointerDown()");
                    sTouching = true;
                    sAuthRequested = true;
                    sAuthSetAt = System.currentTimeMillis();
                    runOnMainSync(new Runnable() {
                        @Override
                        public void run() {
                            requestShow("finger-down");
                            repaintIcon(true);
                        }
                    });
                }
            };

            XposedBridge.hookAllMethods(controller, "onFingerDown", fingerDownHook);
            XposedBridge.hookAllMethods(controller, "onPointerDown", fingerDownHook);
            XposedBridge.hookAllMethods(controller, "onUdfpsPointerDown", fingerDownHook);
            XposedBridge.hookAllMethods(controller, "onTouch", fingerDownHook);

            XC_MethodHook fingerUpHook = new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    log("onFingerUp/PointerUp()");
                    sTouching = false;
                    runOnMainSync(new Runnable() {
                        @Override
                        public void run() { repaintIcon(false); }
                    });
                }
            };

            XposedBridge.hookAllMethods(controller, "onFingerUp", fingerUpHook);
            XposedBridge.hookAllMethods(controller, "onPointerUp", fingerUpHook);
            XposedBridge.hookAllMethods(controller, "onUdfpsPointerUp", fingerUpHook);

            Class<?> udfpsView = findClass(
                    "com.android.systemui.biometrics.UdfpsView", lp.classLoader);
            if (udfpsView != null) {
                XposedBridge.hookAllMethods(udfpsView, "onIlluminated", new XC_MethodHook() {
                    @Override
                    protected void beforeHookedMethod(MethodHookParam param) {
                        log("UdfpsView.onIlluminated()");
                        sTouching = true;
                        sAuthRequested = true;
                        sAuthSetAt = System.currentTimeMillis();
                        runOnMainSync(new Runnable() {
                            @Override public void run() { repaintIcon(true); }
                        });
                    }
                });
            }
        } catch (Throwable t) {
            log("udfps hook skipped: " + t);
        }
    }

    private static void hookEnrollmentUi(final LoadPackageParam lp) {
        final String[] classes = new String[] {
                "com.android.systemui.biometrics.UdfpsEnrollView",
                "com.android.systemui.biometrics.UdfpsEnrollHelper"
        };
        XC_MethodHook enrollmentHook = new XC_MethodHook() {
            private void activate(String reason) {
                sAuthRequested = true;
                sAuthSetAt = System.currentTimeMillis();
                sAppAuthRequested = false;
                runOnMainSync(new Runnable() {
                    @Override public void run() {
                        requestShow(reason);
                        repaintIcon(isTouchVisual());
                    }
                });
            }

            @Override protected void afterHookedMethod(MethodHookParam param) {
                activate("enrollment-ui");
            }
        };
        for (String name : classes) {
            try {
                Class<?> cls = findClass(name, lp.classLoader);
                if (cls == null) continue;
                XposedBridge.hookAllConstructors(cls, enrollmentHook);
                XposedBridge.hookAllMethods(cls, "onEnrollmentProgress", enrollmentHook);
                XposedBridge.hookAllMethods(cls, "onEnrollmentHelp", enrollmentHook);
                XposedBridge.hookAllMethods(cls, "updateProgress", enrollmentHook);
                log("enrollment hooks installed: " + name);
            } catch (Throwable t) {
                log("enrollment hook failed for " + name + ": " + t);
            }
        }
    }

    /* ------------------------------------------------------------------ */
    /* Part 4: fingerprint auth                                            */
    /* ------------------------------------------------------------------ */

    private static void markAuthRequested(String source) {
        long now = System.currentTimeMillis();
        log("markAuthRequested(" + source + ")");
        sAuthRequested = true;
        sAuthSetAt = now;
    }

    private static void hookFingerprintAuth(LoadPackageParam lp) {
        try {
            Class<?> auth = findClass(
                    "com.android.systemui.biometrics.AuthController", lp.classLoader);
            if (auth == null) return;

            XC_MethodHook appAuthStartHook = new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    log("BiometricPrompt/App Auth requested: " + (param.method != null ? param.method.getName() : "auth"));
                    sAppAuthRequested = true;
                    sAuthRequested = true;
                    sAuthSetAt = System.currentTimeMillis();
                    runOnMainSync(new Runnable() {
                        @Override public void run() {
                            requestShow("app-auth");
                            repaintIcon(isTouchVisual());
                        }
                    });
                }
            };

            XposedBridge.hookAllMethods(auth, "showAuthenticationDialog", appAuthStartHook);
            XposedBridge.hookAllMethods(auth, "onBiometricPromptShown", appAuthStartHook);
            XposedBridge.hookAllMethods(auth, "showBiometricPrompt", appAuthStartHook);
            XposedBridge.hookAllMethods(auth, "onStartFingerprintNow", appAuthStartHook);
            XposedBridge.hookAllMethods(auth, "onAcquired", appAuthStartHook);

            XC_MethodHook appAuthEndHook = new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    log("BiometricPrompt/App Auth ended: " + (param.method != null ? param.method.getName() : "end"));
                    sAuthRequested = false;
                    sAppAuthRequested = false;
                    sTouching = false;
                    runOnMainSync(new Runnable() {
                        @Override public void run() { requestHide("app-auth-end"); }
                    });
                }
            };

            XposedBridge.hookAllMethods(auth, "hideAuthenticationDialog", appAuthEndHook);
            XposedBridge.hookAllMethods(auth, "onBiometricError", appAuthEndHook);
            XposedBridge.hookAllMethods(auth, "onBiometricAuthenticated", appAuthEndHook);
            XposedBridge.hookAllMethods(auth, "onDialogDismissed", appAuthEndHook);
            XposedBridge.hookAllMethods(auth, "onBiometricPromptDismissed", appAuthEndHook);
        } catch (Throwable t) {
            log("auth hook skipped: " + t);
        }
    }

    /* ------------------------------------------------------------------ */
    /* helpers                                                             */
    /* ------------------------------------------------------------------ */

    private static Handler handler() {
        if (sHandler == null) sHandler = new Handler(Looper.getMainLooper());
        return sHandler;
    }

    private static void log(String msg) {
        Log.i(TAG, msg);
        try { XposedBridge.log(TAG + ": " + msg); } catch (Throwable ignored) {}
    }

    private static String getStr(String key, String def) {
        try {
            Class<?> sp = Class.forName("android.os.SystemProperties");
            Method m = sp.getMethod("get", String.class, String.class);
            Object v = m.invoke(null, key, def);
            return v instanceof String ? (String) v : def;
        } catch (Throwable t) {
            return def;
        }
    }

    private static int getInt(String key, int def) {
        try { return Integer.parseInt(getStr(key, String.valueOf(def)).trim()); }
        catch (Throwable t) { return def; }
    }

    private static boolean getBool(String key, boolean def) {
        String v = getStr(key, def ? "true" : "false").trim();
        return "1".equals(v) || "true".equalsIgnoreCase(v) || "yes".equalsIgnoreCase(v);
    }

    private static double getDoubleProp(String key, double def) {
        try { return Double.parseDouble(getStr(key, String.valueOf(def)).trim()); }
        catch (Throwable t) { return def; }
    }
}
