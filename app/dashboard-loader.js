/*
 * nd2cn Track Dash - GUI hook (ES5, Opera Presto 12)
 *
 * Loaded by the nd2cn GuiConfig loader:
 *     utility.loadScript("file:///.../dashboard-loader.js");
 *
 * What it does
 *   1. Adds one entry to the factory Applications list by wrapping
 *      systemApp.prototype._initApplicationsDataList (the list of all items)
 *      and _updateApplicationStructure (which items the "Applications"
 *      context shows; the firmware rebuilds that table, so it is wrapped
 *      rather than edited once).
 *   2. Selecting the entry shows dashboard.html in an iframe that covers the
 *      800x416 content area below the status bar.
 *
 * Why an overlay and not a real framework app: MMUI (the native state
 * machine) only knows the factory apps and contexts. Faking a context change
 * means lying to the GUI framework's state machine, whose timeouts restart
 * the CMU. The overlay never touches it: MMUI and the framework stay in
 * system/Applications, and the overlay closes itself the moment MMUI changes
 * context (Home, Nav, phone call, reverse camera, ...). The status bar, its
 * notifications and warning pop-ups stay on top (z-index 10+).
 *
 * Nothing here writes to storage. The session state the dashboard hands
 * back (peak g, timer start) is kept in memory until power-off.
 */
(function (window) {
    if (window.__nd2cnDash) { return; }

    var APP_NAME   = "nd2cndash";                     // appData.appName of our list item
    var MMUI_EVENT = "Nd2cnSelectTrackDash";          // never sent to MMUI
    var MSG        = "nd2cn-dash:";                   // postMessage prefix shared with dashboard.html
    var FRAME_ID   = "nd2cnDashFrame";
    var FALLBACK_URL = "file:///data/nd2cn/app/dashboard.html";
    var SB_TITLE   = { zh_CN: "\u8d5b\u9053\u4eea\u8868", en: "Track Dash" };
    var ITEM_TEXT  = { zh_CN: "\u8d5b\u9053\u4eea\u8868", en: "Track Dash" };

    var document = window.document;
    var st = {
        frame: null,          // the iframe while the dashboard is open
        saved: null,          // session state string from the dashboard
        hooked: false,        // framework hooks installed
        protoDone: false,
        instDone: false,
        tries: 0
    };

    function fw() { return window.framework; }

    function lang() {
        try {
            if (fw() && fw().localize && fw().localize.getCurrLang() === "zh_CN") { return "zh_CN"; }
        } catch (e) {}
        return "en";
    }

    // dashboard.html sits next to this script
    function dashUrl() {
        var s = document.getElementsByTagName("script"), i, src, cut;
        for (i = 0; i < s.length; i++) {
            src = s[i].src || "";
            cut = src.indexOf("dashboard-loader.js");
            if (cut >= 0) { return src.substring(0, cut) + "dashboard.html"; }
        }
        return FALLBACK_URL;
    }

    // ---- list entry ----

    function makeItem() {
        return {
            appData: { appName: APP_NAME, isVisible: true, audioSourceId: "None", mmuiEvent: MMUI_EVENT },
            text1: ITEM_TEXT[lang()],
            disabled: false,
            itemStyle: "style01",
            hasCaret: false
        };
    }

    function findItem(app) {
        var items = app && app._masterApplicationDataList && app._masterApplicationDataList.items, i;
        if (!items) { return null; }
        for (i = 0; i < items.length; i++) {
            if (items[i] && items[i].appData && items[i].appData.appName === APP_NAME) { return items[i]; }
        }
        return null;
    }

    function addItem(app) {
        var list = app && app._masterApplicationDataList;
        if (!list || !list.items || findItem(app)) { return; }
        list.items.push(makeItem());
    }

    function addName(app) {
        var names = app && app._applicationsCtxtWiseAppNames && app._applicationsCtxtWiseAppNames.Applications, i;
        if (!names || typeof names.length !== "number") { return; }
        for (i = 0; i < names.length; i++) {
            if (names[i] === APP_NAME) { return; }
        }
        names.push(APP_NAME);
    }

    function isOurs(appData) {
        return !!appData && appData.appName === APP_NAME;
    }

    function patchPrototype() {
        var proto = window.systemApp && window.systemApp.prototype;
        var init, structure, select, ready;
        if (st.protoDone || !proto || typeof proto._initApplicationsDataList !== "function") { return; }
        st.protoDone = true;

        init = proto._initApplicationsDataList;
        proto._initApplicationsDataList = function () {
            var r = init.apply(this, arguments);
            try { addItem(this); addName(this); } catch (e) {}
            return r;
        };

        if (typeof proto._updateApplicationStructure === "function") {
            structure = proto._updateApplicationStructure;
            proto._updateApplicationStructure = function () {
                var r = structure.apply(this, arguments);
                try { addName(this); } catch (e) {}
                return r;
            };
        }

        if (typeof proto._menuItemSelectCallback === "function") {
            select = proto._menuItemSelectCallback;
            proto._menuItemSelectCallback = function (listCtrlObj, appData, params) {
                if (isOurs(appData)) { open(); return; }
                return select.apply(this, arguments);
            };
        }

        // the entry follows the system language each time the list is shown
        if (typeof proto._readyApplications === "function") {
            ready = proto._readyApplications;
            proto._readyApplications = function () {
                var it;
                try { it = findItem(this); if (it) { it.text1 = ITEM_TEXT[lang()]; } } catch (e) {}
                return ready.apply(this, arguments);
            };
        }
    }

    // The system app may already exist when this script loads. Its context
    // table then holds callbacks bound to the unpatched functions.
    function patchInstance() {
        var app, tbl, ctx, props, tmpl;
        if (st.instDone || !st.protoDone) { return; }
        try { app = fw() && fw().getAppInstance ? fw().getAppInstance("system") : null; } catch (e) { app = null; }
        if (!app || !app._masterApplicationDataList) { return; }
        st.instDone = true;
        try {
            addItem(app);
            addName(app);
            tbl = app._contextTable;
            ctx = tbl && tbl.Applications;
            props = ctx && ctx.controlProperties && ctx.controlProperties.List2Ctrl;
            if (props) { props.selectCallback = app._menuItemSelectCallback.bind(app); }
            if (ctx) { ctx.readyFunction = app._readyApplications.bind(app); }
            // list already on screen: swap its callback and rebuild it
            if (app._currentContext && app._currentContext.ctxtId === "Applications" && app._currentContextTemplate) {
                tmpl = app._currentContextTemplate;
                if (tmpl.list2Ctrl && tmpl.list2Ctrl.properties) {
                    tmpl.list2Ctrl.properties.selectCallback = app._menuItemSelectCallback.bind(app);
                }
                app._readyApplications();
            }
        } catch (e2) {}
    }

    // ---- framework hooks (installed on first open) ----

    function shouldClose(msg) {
        var top;
        if (!msg) { return false; }
        if (msg.msgType === "ctxtChg") { return true; }
        if (msg.msgType === "focusStack") {
            top = msg.appIdList && msg.appIdList[0];
            return !!top && top.id !== "system";
        }
        return false;
    }

    function installHooks() {
        var f = fw(), common, route, ctl;
        if (st.hooked || !f || !f.common) { return st.hooked; }
        common = f.common;
        if (typeof f.routeMmuiMsg !== "function" || typeof common.handleControllerEvent !== "function") { return false; }
        st.hooked = true;

        // MMUI changed context: the dashboard gives way before the framework reacts
        route = f.routeMmuiMsg;
        f.routeMmuiMsg = function (msg) {
            try { if (st.frame && shouldClose(msg)) { close(false); } } catch (e) {}
            return route.apply(this, arguments);
        };

        // commander: Back closes the dashboard, everything else goes to it
        // instead of to the list underneath
        ctl = common.handleControllerEvent;
        common.handleControllerEvent = function (eventId, firstEvent) {
            if (st.frame && eventId !== "controllerActive" && eventId !== "touchActive") {
                try {
                    if (eventId === "goBack") { close(true); }
                    else if (!firstEvent) { send("key:" + eventId); }
                } catch (e) {}
                return;
            }
            return ctl.apply(this, arguments);
        };
        return true;
    }

    // ---- overlay ----

    function send(text) {
        try {
            if (st.frame && st.frame.contentWindow) { st.frame.contentWindow.postMessage(MSG + text, "*"); }
        } catch (e) {}
    }

    function open() {
        var f, l;
        if (st.frame) { return; }
        if (!installHooks()) { return; }       // without the hooks the overlay could not be closed
        l = lang();
        f = document.createElement("iframe");
        f.id = FRAME_ID;
        f.setAttribute("frameborder", "0");
        f.setAttribute("scrolling", "no");
        f.style.cssText = "position:absolute;left:0;top:64px;width:800px;height:416px;" +
                          "border:0;margin:0;padding:0;overflow:hidden;background:#050707;z-index:9;";
        f.src = dashUrl() + "#lang=" + l;
        document.body.appendChild(f);
        st.frame = f;
        try { fw().common.setSbName(SB_TITLE[l]); } catch (e) {}
    }

    // restoreTitle: true when the user leaves the dashboard and the
    // Applications list underneath becomes visible again
    function close(restoreTitle) {
        var f = st.frame;
        if (!f) { return; }
        st.frame = null;
        try { if (f.parentNode) { f.parentNode.removeChild(f); } } catch (e) {}
        if (restoreTitle) {
            try {
                if (fw().getCurrentApp() === "system" && fw().getCurrCtxtId() === "Applications") {
                    fw().common.setSbNameId("system", "Applications");
                }
            } catch (e2) {}
        }
    }

    function onMessage(e) {
        var d = e ? e.data : null;
        if (typeof d !== "string" || d.indexOf(MSG) !== 0) { return; }
        if (!st.frame || e.source !== st.frame.contentWindow) { return; }
        d = d.substring(MSG.length);
        if (d === "ready") {
            if (st.saved) { send("init:" + st.saved); }
        } else if (d === "close") {
            close(true);
        } else if (d.indexOf("state:") === 0 && d.length < 512) {
            st.saved = d.substring(6);
        }
    }

    // ---- start ----

    function tryPatch() {
        try { patchPrototype(); patchInstance(); } catch (e) {}
        return st.protoDone && st.instDone;
    }

    window.__nd2cnDash = { open: open, close: function () { close(true); }, isOpen: function () { return !!st.frame; } };

    if (window.addEventListener) { window.addEventListener("message", onMessage, false); }

    // systemApp.js is loaded by the framework shortly after start-up; keep
    // looking until both the prototype and the instance are patched.
    if (!tryPatch()) {
        (function wait() {
            if (tryPatch()) { return; }
            st.tries++;
            window.setTimeout(wait, st.tries < 120 ? 250 : 2000);
        })();
    }
})(window);
