package de.robv.android.xposed.callbacks;

import android.content.pm.ApplicationInfo;

/** Compile-time stub only. */
public class XC_LoadPackage {
    public static class LoadPackageParam {
        public String packageName;
        public ClassLoader classLoader;
        public boolean isFirstApplication;
        public ApplicationInfo appInfo;
        public String processName;
    }
}