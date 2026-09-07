import QtQuick
import QtQuick.Layouts
import QtCore
import Quickshell
import Quickshell.Io
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets

ContentPage {
    id: root
    forceWidth: true

    // Draft only: nothing here touches Config.options until Apply.
    // Closing or navigating away destroys the page and discards the draft.
    property string draftLayout: ""
    property string draftVariant: ""
    property string draftOptions: ""
    property var layoutRaws: []
    property var variantRaws: ({})
    property bool draftDirty: root.draftLayout !== (Config.options.input.layout || "")
        || root.draftVariant !== (Config.options.input.variant || "")
        || root.draftOptions !== (Config.options.input.options || "")

    readonly property string applyScript: FileUtils.trimFileProtocol(`${Directories.scriptPath}/hyprland/input-layout-apply`)

    // "verified": bare "", us, or tr. Anything else (including any variant or
    // options, which can remap keys or modifiers) leaves typing supported
    // while shortcut compatibility stays unverified.
    function shortcutStatus() {
        if (root.draftVariant !== "" || root.draftOptions !== "" || root.draftLayout.includes(",")) return "unverified";
        if (root.draftLayout === "" || root.draftLayout === "us" || root.draftLayout === "tr") return "verified";
        return "unverified";
    }

    function layoutModel() {
        const stock = [{ displayName: Translation.tr("Stock default"), value: "" }];
        const known = root.layoutRaws.map(e => ({ displayName: `${e.name} (${e.value})`, value: e.value }));
        if (root.draftLayout !== "" && !root.layoutRaws.some(e => e.value === root.draftLayout)) {
            known.push({ displayName: Translation.tr("Custom") + ` (${root.draftLayout})`, value: root.draftLayout });
        }
        return stock.concat(known);
    }

    function variantModel() {
        const none = [{ displayName: Translation.tr("Default (none)"), value: "" }];
        const raws = root.variantRaws[root.draftLayout] || [];
        const known = raws.map(e => ({ displayName: `${e.name} (${e.value})`, value: e.value }));
        if (root.draftVariant !== "" && !raws.some(e => e.value === root.draftVariant)) {
            known.push({ displayName: Translation.tr("Custom") + ` (${root.draftVariant})`, value: root.draftVariant });
        }
        return none.concat(known);
    }

    Component.onCompleted: {
        root.draftLayout = (Config.options.input.layout || "").trim();
        root.draftVariant = (Config.options.input.variant || "").trim();
        root.draftOptions = (Config.options.input.options || "").trim();
    }

    Process {
        id: xkbDataProc
        running: true
        command: ["cat", "/usr/share/X11/xkb/rules/base.lst"]
        stdout: StdioCollector {
            id: xkbCollector
            onStreamFinished: {
                const layouts = [];
                const variants = {};
                let section = "";
                for (const raw of xkbCollector.text.split("\n")) {
                    const line = raw.trim();
                    if (line === "! layout" || line === "! variant" || line === "! option") {
                        section = line;
                        continue;
                    }
                    if (line === "" || line.startsWith("!")) continue;
                    if (section === "! layout") {
                        const m = raw.match(/^\s*(\S+)\s+(.+)$/);
                        if (m) layouts.push({ value: m[1], name: m[2].trim() });
                    } else if (section === "! variant") {
                        const m = raw.match(/^\s*(\S+)\s+(\S+?)\s+(.+)$/);
                        if (m) {
                            const layout = m[2].endsWith(":") ? m[2].slice(0, -1) : m[2];
                            (variants[layout] = variants[layout] || []).push({ value: m[1], name: m[3].trim() });
                        }
                    }
                }
                const byName = (a, b) => a.name < b.name ? -1 : 1;
                if (layouts.length > 0) {
                    root.layoutRaws = layouts.sort(byName);
                } else {
                    root.layoutRaws = [
                        { value: "us", name: "English (US)" },
                        { value: "tr", name: "Turkish" },
                        { value: "de", name: "German" },
                        { value: "fr", name: "French" },
                    ];
                }
                const sorted = {};
                for (const k in variants) sorted[k] = variants[k].sort(byName);
                root.variantRaws = sorted;
            }
        }
    }

    Process {
        id: validateProc
        stdout: StdioCollector {
            id: validateCollector
        }
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0) {
                applyResult.text = validateCollector.text.trim() || Translation.tr("Invalid keyboard setup.");
                return;
            }
            Config.options.input.layout = root.draftLayout;
            Config.options.input.variant = root.draftVariant;
            Config.options.input.options = root.draftOptions;
            applyProc.command = [root.applyScript, "--apply",
                "--layout", root.draftLayout, "--variant", root.draftVariant, "--options", root.draftOptions];
            applyProc.running = false;
            applyProc.running = true;
        }
    }

    Process {
        id: applyProc
        stdout: StdioCollector {
            id: applyCollector
        }
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0) {
                applyResult.text = applyCollector.text.trim() || Translation.tr("Apply failed.");
                return;
            }
            applyResult.text = (root.draftLayout === "" && root.draftVariant === "" && root.draftOptions === "")
                ? Translation.tr("Cleared. Using stock keyboard.")
                : Translation.tr("Applied.");
            reloadProc.running = true;
        }
    }

    Process {
        id: reloadProc
        command: ["hyprctl", "reload"]
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0) {
                applyResult.text = Translation.tr("Applied, but Hyprland reload failed.");
            }
        }
    }


    ContentSection {
        icon: "keyboard"
        title: Translation.tr("Keyboard layout")

        StyledText {
            Layout.fillWidth: true
            visible: HyprlandXkb.currentLayoutName.length > 0
            color: Appearance.colors.colSubtext
            font.pixelSize: Appearance.font.pixelSize.small
            text: Translation.tr("In use now: %1").arg(HyprlandXkb.currentLayoutName)
                + (root.draftDirty ? Translation.tr(" · Unsaved changes") : "")
        }

        ContentSubsection {
            title: Translation.tr("Layout")
            tooltip: Translation.tr("Match this to your physical keyboard.")

            StyledComboBox {
                buttonIcon: "keyboard"
                textRole: "displayName"
                model: root.layoutModel()
                currentIndex: root.layoutModel().findIndex(e => e.value === root.draftLayout)
                onActivated: index => {
                    root.draftLayout = root.layoutModel()[index].value;
                    root.draftVariant = "";
                }
            }
        }

        ContentSubsection {
            title: Translation.tr("Variant")
            tooltip: Translation.tr("A flavor of the chosen layout. Most keyboards use Default.")

            StyledComboBox {
                buttonIcon: "keyboard"
                enabled: root.variantModel().length > 1 || root.draftVariant !== ""
                textRole: "displayName"
                model: root.variantModel()
                currentIndex: root.variantModel().findIndex(e => e.value === root.draftVariant)
                onActivated: index => {
                    root.draftVariant = root.variantModel()[index].value;
                }
            }
        }

        ContentSubsection {
            title: Translation.tr("Advanced")
            tooltip: Translation.tr("Extra options for experts. Custom options leave shortcut verification off.")

            MaterialTextField {
                Layout.fillWidth: true
                placeholderText: Translation.tr("Options, e.g. grp:alt_shift_toggle")
                text: root.draftOptions
                onEditingFinished: root.draftOptions = text.trim()
            }
        }

        ConfigRow {
            RippleButtonWithIcon {
                materialIcon: "settings_backup_restore"
                mainText: Translation.tr("Reset")
                enabled: root.draftLayout !== "" || root.draftVariant !== "" || root.draftOptions !== ""
                onClicked: {
                    root.draftLayout = "";
                    root.draftVariant = "";
                    root.draftOptions = "";
                }
                StyledToolTip {
                    text: Translation.tr("Clear input intent and return to stock")
                }
            }
            RippleButtonWithIcon {
                materialIcon: "restart_alt"
                mainText: Translation.tr("Apply")
                enabled: root.draftDirty
                onClicked: {
                    applyResult.text = Translation.tr("Validating %1…").arg(
                        root.draftLayout === "" ? Translation.tr("stock") : root.draftLayout);
                    validateProc.command = [root.applyScript, "--check",
                        "--layout", root.draftLayout, "--variant", root.draftVariant, "--options", root.draftOptions];
                    validateProc.running = false;
                    validateProc.running = true;
                }
            }
        }
        StyledText {
            id: applyResult
            Layout.fillWidth: true
            visible: text.length > 0
            color: Appearance.colors.colSubtext
            font.pixelSize: Appearance.font.pixelSize.small
            wrapMode: Text.WordWrap
        }
    }

    ContentSection {
        icon: "fact_check"
        title: Translation.tr("Shortcut compatibility")

        StyledText {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            color: Appearance.colors.colOnLayer1
            text: Translation.tr("Shortcuts follow the symbols shown in your active layout.")
        }
        NoticeBox {
            Layout.fillWidth: true
            materialIcon: root.shortcutStatus() === "unverified" ? "warning" : "check_circle"
            text: root.shortcutStatus() === "verified"
                ? Translation.tr("End-4 shortcuts are verified for this keyboard setup.")
                : Translation.tr("Typing is supported, but End-4 shortcut compatibility has not been verified for this keyboard setup.");
        }
    }

// Hardware keys: capture, assign, enable/disable, remove — applied immediately.
// Independent from the Keyboard layout draft/Apply above; layout Apply never
// touches these mappings and vice versa.
ContentSection {
    id: hwSection
    icon: "action_key"
    title: Translation.tr("Hardware keys")

    // Local truth, read once at load; updated only after a successful apply.
    property var hwRows: []
    property var hwCatalog: []
    property string pickedAction: ""
    property string customCommand: ""

    readonly property string hwkeysScript: FileUtils.trimFileProtocol(`${Directories.scriptPath}/hyprland/hwkeys-apply`)

    function hwReadNormalized() {
        const s = Config.options.hardwareKeys;
        if (!s) return [];
        const b = s.bindings;
        if (!b || typeof b.length !== "number") return [];
        const out = [];
        for (let i = 0; i < b.length; i++) {
            const m = b[i] || {};
            out.push({
                id: String(m.id !== undefined ? m.id : ""),
                code: Number(m.code !== undefined ? m.code : -1),
                action: String(m.action !== undefined ? m.action : ""),
                command: String(m.command !== undefined ? m.command : ""),
                enabled: m.enabled !== false
            });
        }
        return out;
    }

    // Validate, persist, apply, reload — each step gates the next so a failure
    // never presents a half-applied state as done.
    function hwRunOp(nextList) {
        hwSection.hwPendingList = nextList;
        opValidateProc.command = [hwSection.hwkeysScript, "--check",
            "--bindings-json", JSON.stringify(nextList)];
        opValidateProc.running = false;
        opValidateProc.running = true;
    }
    property var hwPendingList: []

    // ---- Capture (observe only; nothing is persisted) ----
    // Events append "keycode state timeMs" lines via io.open inside the Hyprland
    // Lua callback, so no process spawns per key event.
    readonly property string capStatePath: {
        const rt = StandardPaths.standardLocations(StandardPaths.RuntimeLocation);
        const dir = rt.length > 0 ? FileUtils.trimFileProtocol(rt[0]) : "/tmp";
        return dir + "/ii-hwcap";
    }
    property string capState: "idle" // idle|starting|listening|done|timeout|cancelled|error
    property var capEvents: []
    property string capError: ""
    property string capPendingKind: ""
    // Well-established evdev→XF86 names only, keyed by xkb keycode (evdev+8,
    // Hyprland's own event numbering). The raw code is always shown alongside.
    readonly property var capSymByCode: ({
        121: "XF86AudioMute", 122: "XF86AudioLowerVolume", 123: "XF86AudioRaiseVolume",
        256: "XF86AudioMicMute", 172: "XF86AudioPlay", 127: "XF86AudioPause",
        171: "XF86AudioNext", 173: "XF86AudioPrev", 174: "XF86AudioStop",
        232: "XF86MonBrightnessDown", 233: "XF86MonBrightnessUp",
        107: "Print", 225: "XF86Search", 148: "XF86Calculator", 180: "XF86HomePage",
        163: "XF86Mail", 150: "XF86Sleep", 124: "XF86PowerOff", 169: "XF86Eject",
        234: "XF86AudioMedia", 372: "XF86Favorites", 589: "XF86ScreenSaver", 400: "XF86AudioMedia"
    })

    function capLuaPath() {
        return hwSection.capStatePath.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
    }
    function capSetupLua() {
        const p = hwSection.capLuaPath();
        return [
            "if HwCapBind then pcall(function() HwCapBind:remove() end) end",
            "HwCapBind = nil",
            "if HwCapSub then HwCapSub:remove() end",
            "HwCapSub = nil",
            "local f = io.open(\"" + p + "\", \"w\")",
            "if f then f:close() end",
            "hl.define_submap(\"ii-hwcap\", function()",
            "  HwCapBind = hl.bind(\"catchall\", hl.dsp.submap(\"reset\"))",
            "end)",
            "hl.dispatch(hl.dsp.submap(\"ii-hwcap\"))",
            "HwCapSub = hl.on(\"input.keyboard.key\", function(keycode, timeMs, state)",
            "  local g = io.open(\"" + p + "\", \"a\")",
            "  if g then g:write(keycode .. \" \" .. state .. \" \" .. timeMs .. \"\\n\") g:close() end",
            "end)"
        ].join("\n");
    }
    function capCleanupLua() {
        return [
            "hl.dispatch(hl.dsp.submap(\"reset\"))",
            "if HwCapBind then pcall(function() HwCapBind:remove() end) end",
            "HwCapBind = nil",
            "if HwCapSub then HwCapSub:remove() end",
            "HwCapSub = nil"
        ].join("\n");
    }
    function capEnter() {
        hwSection.capEvents = [];
        hwSection.capError = "";
        hwSection.capState = "starting";
        capSetupProc.command = ["hyprctl", "eval", hwSection.capSetupLua()];
        capSetupProc.running = false;
        capSetupProc.running = true;
    }
    function capFinish(kind) {
        capTimeoutTimer.stop();
        capCollectTimer.stop();
        hwSection.capPendingKind = kind;
        capCleanupProc.command = ["hyprctl", "eval", hwSection.capCleanupLua()];
        capCleanupProc.running = false;
        capCleanupProc.running = true;
    }
    function capIngest(text) {
        const evs = [];
        for (const line of text.split("\n")) {
            const m = line.trim().match(/^(-?\d+)\s+(-?\d+)\s+(-?\d+)$/);
            if (m) evs.push({ code: parseInt(m[1], 10), state: parseInt(m[2], 10), time: parseInt(m[3], 10) });
        }
        hwSection.capEvents = evs;
        if (hwSection.capState === "listening" && evs.some(e => e.state === 1) && !capCollectTimer.running) {
            capCollectTimer.start();
        }
    }
    function capPresses() {
        return hwSection.capEvents.filter(e => e.state === 1);
    }
    function capFirstCode() {
        const p = hwSection.capPresses();
        return p.length > 0 ? p[0].code : -1;
    }
    function capSym() {
        const s = hwSection.capSymByCode[hwSection.capFirstCode()];
        return s !== undefined ? s : null;
    }
    function capMatch() {
        const s = hwSection.capSym();
        if (s === null) return null;
        const found = HyprlandKeybinds.keybinds.find(b => b.key === s);
        return found !== undefined ? found : null;
    }
    function capCounts() {
        let press = 0, release = 0, other = 0;
        for (const e of hwSection.capEvents) {
            if (e.state === 1) press++;
            else if (e.state === 0) release++;
            else other++;
        }
        return { press, release, other };
    }
    // Distinct pressed codes in one attempt; more than one means a chord or
    // macro, which Slice 2A leaves discovery-only.
    function capPressCodes() {
        const seen = [];
        for (const e of hwSection.capPresses()) {
            if (!seen.includes(e.code)) seen.push(e.code);
        }
        return seen;
    }
    function capActionLabel(id) {
        const found = hwSection.hwCatalog.find(a => a.value === id);
        return found !== undefined ? found.displayName : id;
    }
    function assignEligible() {
        if (hwSection.capState !== "done" || hwSection.capMatch() !== null) return false;
        const codes = hwSection.capPressCodes();
        if (codes.length !== 1 || codes[0] <= 0) return false;
        return !hwSection.hwRows.some(m => m.code === codes[0]);
    }

    Component.onCompleted: {
        hwSection.hwRows = hwSection.hwReadNormalized();
    }

    Timer {
        id: capTimeoutTimer
        interval: 15000
        repeat: false
        onTriggered: {
            if (hwSection.capState === "listening") hwSection.capFinish("timeout");
        }
    }
    Timer {
        id: capCollectTimer
        interval: 1500
        repeat: false
        onTriggered: {
            if (hwSection.capState === "listening") hwSection.capFinish("done");
        }
    }
    Process {
        id: capSetupProc
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0) {
                hwSection.capError = Translation.tr("Capture setup failed.");
                hwSection.capFinish("error");
                return;
            }
            capVerifyProc.command = ["hyprctl", "submap"];
            capVerifyProc.running = false;
            capVerifyProc.running = true;
        }
    }
    Process {
        id: capVerifyProc
        stdout: StdioCollector {
            id: capVerifyCollector
        }
        onExited: (exitCode, exitStatus) => {
            if (exitCode === 0 && capVerifyCollector.text.trim() === "ii-hwcap") {
                hwSection.capState = "listening";
                capTimeoutTimer.start();
            } else {
                hwSection.capError = Translation.tr("Capture submap did not activate.");
                hwSection.capFinish("error");
            }
        }
    }
    Process {
        id: capCleanupProc
        onExited: (exitCode, exitStatus) => {
            capVerifyDefaultProc.command = ["hyprctl", "submap"];
            capVerifyDefaultProc.running = false;
            capVerifyDefaultProc.running = true;
        }
    }
    Process {
        id: capVerifyDefaultProc
        stdout: StdioCollector {
            id: capVerifyDefaultCollector
        }
        onExited: (exitCode, exitStatus) => {
            if (exitCode === 0 && capVerifyDefaultCollector.text.trim() === "default") {
                hwSection.capState = hwSection.capPendingKind;
            } else {
                hwSection.capError = Translation.tr("Capture may still be active — press Cancel again.");
                hwSection.capState = "error";
            }
        }
    }
    Process {
        id: catalogProc
        running: true
        command: [hwSection.hwkeysScript, "--catalog"]
        stdout: StdioCollector {
            id: catalogCollector
            onStreamFinished: {
                try {
                    const list = JSON.parse(catalogCollector.text).map(a => ({
                        displayName: a.label, value: a.id, needsCommand: a.needsCommand
                    }));
                    hwSection.hwCatalog = list;
                    if (hwSection.pickedAction === "" && list.length > 0) hwSection.pickedAction = list[0].value;
                } catch (e) {
                    console.error("[HwKeys] catalog parse failed:", e);
                }
            }
        }
    }
    Process {
        id: opValidateProc
        stdout: StdioCollector {
            id: opValidateCollector
        }
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0) {
                hwResult.text = opValidateCollector.text.trim() || Translation.tr("Invalid hardware-key mapping.");
                return;
            }
            Config.options.hardwareKeys.bindings =
                JSON.parse(JSON.stringify(hwSection.hwPendingList));
            opApplyProc.command = [hwSection.hwkeysScript, "--apply",
                "--bindings-json", JSON.stringify(hwSection.hwPendingList)];
            opApplyProc.running = false;
            opApplyProc.running = true;
        }
    }
    Process {
        id: opApplyProc
        stdout: StdioCollector {
            id: opApplyCollector
        }
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0) {
                hwResult.text = opApplyCollector.text.trim() || Translation.tr("Hardware-key apply failed.");
                return;
            }
            hwSection.hwRows = JSON.parse(JSON.stringify(hwSection.hwPendingList));
            hwResult.text = "";
            opReloadProc.running = true;
        }
    }
    Process {
        id: opReloadProc
        command: ["hyprctl", "reload"]
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0) {
                hwResult.text = Translation.tr("Saved, but Hyprland reload failed.");
            }
        }
    }
    FileView {
        id: capFile
        path: Qt.resolvedUrl("file://" + hwSection.capStatePath)
        watchChanges: true
        onFileChanged: {
            reload();
            hwSection.capIngest(text());
        }
        onLoadFailed: {}
    }

    Component.onDestruction: {
        if (hwSection.capState === "listening" || hwSection.capState === "starting") {
            Quickshell.execDetached(["hyprctl", "eval", hwSection.capCleanupLua()]);
        }
    }

    ContentSubsection {
        title: Translation.tr("Assigned mappings")
        tooltip: Translation.tr("Saved immediately when changed.")

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 4
            visible: hwSection.hwRows.length > 0
            Repeater {
                model: hwSection.hwRows
                delegate: ConfigRow {
                    Layout.fillWidth: true
                    required property var modelData
                    required property int index
                    KeyboardKey {
                        Layout.alignment: Qt.AlignVCenter
                        key: "code " + modelData.code
                    }
                    StyledText {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        wrapMode: Text.WordWrap
                        color: Appearance.colors.colOnLayer1
                        text: hwSection.capActionLabel(modelData.action)
                            + (modelData.enabled === false ? Translation.tr(" (off)") : "")
                    }
                    StyledSwitch {
                        Layout.alignment: Qt.AlignVCenter
                        checked: modelData.enabled !== false
                        onClicked: {
                            const next = hwSection.hwRows.map((m, j) => j === index ? Object.assign({}, m, {
                                        enabled: !(m.enabled !== false) }) : m);
                            hwSection.hwRunOp(next);
                        }
                    }
                    RippleButtonWithIcon {
                        Layout.alignment: Qt.AlignVCenter
                        mainText: Translation.tr("Remove")
                        onClicked: {
                            hwSection.hwRunOp(hwSection.hwRows.slice(0, index).concat(hwSection.hwRows.slice(index + 1)));
                        }
                    }
                }
            }
        }
        StyledText {
            Layout.fillWidth: true
            visible: hwSection.hwRows.length === 0
            color: Appearance.colors.colSubtext
            font.pixelSize: Appearance.font.pixelSize.small
            text: Translation.tr("- No hardware keys assigned yet.")
        }
        StyledText {
            id: hwResult
            Layout.fillWidth: true
            visible: text.length > 0
            color: Appearance.colors.colSubtext
            font.pixelSize: Appearance.font.pixelSize.small
            wrapMode: Text.WordWrap
        }
    }

    ContentSubsection {
        title: Translation.tr("Capture")
        tooltip: Translation.tr("Capture observes one key attempt and reports what Hyprland receives.")

        StyledText {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            color: Appearance.colors.colOnLayer1
            text: Translation.tr("Find out what a special key sends. Nothing is changed by capturing.")
        }
        ConfigRow {
            RippleButtonWithIcon {
                mainText: Translation.tr("Capture key")
                enabled: !["starting", "listening"].includes(hwSection.capState)
                onClicked: hwSection.capEnter()
            }
            RippleButtonWithIcon {
                visible: hwSection.capState === "starting" || hwSection.capState === "listening"
                mainText: Translation.tr("Cancel")
                onClicked: hwSection.capFinish("cancelled")
            }
        }
        StyledText {
            Layout.fillWidth: true
            visible: hwSection.capState === "listening"
            color: Appearance.colors.colSubtext
            font.pixelSize: Appearance.font.pixelSize.small
            text: Translation.tr("Listening… press one special key (15 s).")
        }
        ColumnLayout {
            Layout.fillWidth: true
            visible: hwSection.capState === "done"
            spacing: 4
            RowLayout {
                spacing: 8
                KeyboardKey {
                    Layout.alignment: Qt.AlignVCenter
                    key: (hwSection.capSym() ?? ("code " + hwSection.capFirstCode()))
                }
                StyledText {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    wrapMode: Text.WordWrap
                    color: Appearance.colors.colOnLayer1
                    text: {
                        const c = hwSection.capCounts();
                        let s = Translation.tr("keycode %1 · %2 press · %3 release").arg(hwSection.capFirstCode()).arg(c.press).arg(c.release);
                        if (c.other > 0) s += Translation.tr(" · %1 other").arg(c.other);
                        return s;
                    }
                }
            }
            StyledText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                color: Appearance.colors.colOnLayer1
                text: {
                    const m = hwSection.capMatch();
                    if (m) {
                        const what = m.description && m.description.length > 0 ? m.description : Translation.tr("bound (no description)");
                        return Translation.tr("Bound now: %1").arg(what);
                    }
                    if (hwSection.capSym() !== null) return Translation.tr("No live symbolic binding found.");
                    return Translation.tr("No symbolic name established — keycode-bound entries cannot be reverse-matched.");
                }
            }
            StyledText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                color: Appearance.colors.colSubtext
                font.pixelSize: Appearance.font.pixelSize.small
                text: {
                    let s = Translation.tr("Hyprland doesn't report which device sent this event.");
                    if (hwSection.capCounts().press > 1) s += " " + Translation.tr("%1 press events observed for one attempt (reported as-is).").arg(hwSection.capCounts().press);
                    return s;
                }
            }
            StyledText {
                Layout.fillWidth: true
                visible: !hwSection.assignEligible() && hwSection.capPressCodes().length > 1
                wrapMode: Text.WordWrap
                color: Appearance.colors.colSubtext
                font.pixelSize: Appearance.font.pixelSize.small
                text: Translation.tr("Multiple keys in one attempt look like a chord or macro; remapping those is deferred.");
            }
            StyledText {
                Layout.fillWidth: true
                visible: !hwSection.assignEligible() && hwSection.capPressCodes().length <= 1 && hwSection.hwRows.some(m => m.code === hwSection.capFirstCode())
                wrapMode: Text.WordWrap
                color: Appearance.colors.colSubtext
                font.pixelSize: Appearance.font.pixelSize.small
                text: Translation.tr("This keycode is already assigned below.");
            }
        }
        StyledText {
            Layout.fillWidth: true
            visible: hwSection.capState === "timeout"
            wrapMode: Text.WordWrap
            color: Appearance.colors.colSubtext
            font.pixelSize: Appearance.font.pixelSize.small
            text: Translation.tr("No key reached Hyprland within 15 s. Only keys Hyprland receives can be bound here.");
        }
        StyledText {
            Layout.fillWidth: true
            visible: hwSection.capState === "cancelled"
            color: Appearance.colors.colSubtext
            font.pixelSize: Appearance.font.pixelSize.small
            text: Translation.tr("Capture cancelled.");
        }
        StyledText {
            Layout.fillWidth: true
            visible: hwSection.capState === "error"
            wrapMode: Text.WordWrap
            color: Appearance.colors.colSubtext
            font.pixelSize: Appearance.font.pixelSize.small
            text: hwSection.capError.length > 0 ? hwSection.capError : Translation.tr("Capture failed.");
        }
    }

    ContentSubsection {
        title: Translation.tr("Assign action")
        tooltip: Translation.tr("Assign the captured raw keycode; saved immediately.")
        visible: hwSection.assignEligible()

        StyledText {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            color: Appearance.colors.colSubtext
            font.pixelSize: Appearance.font.pixelSize.small
            text: Translation.tr("The key may also keep its built-in system behavior.")
        }
        ConfigSelectionArray {
            currentValue: hwSection.pickedAction
            onSelected: newValue => {
                hwSection.pickedAction = newValue;
            }
            options: hwSection.hwCatalog
        }
        MaterialTextField {
            Layout.fillWidth: true
            visible: (hwSection.hwCatalog.find(a => a.value === hwSection.pickedAction) || {}).needsCommand === true
            placeholderText: Translation.tr("Command, e.g. notify-send Hello")
            text: hwSection.customCommand
            onEditingFinished: hwSection.customCommand = text.trim()
        }
        ConfigRow {
            RippleButtonWithIcon {
                mainText: Translation.tr("Save mapping")
                enabled: hwSection.pickedAction !== "" && (hwSection.pickedAction !== "custom" || hwSection.customCommand.trim() !== "")
                onClicked: {
                    const pick = hwSection.pickedAction;
                    hwSection.hwRunOp(hwSection.hwRows.concat([{
                        id: "hw-" + Date.now().toString(36) + Math.floor(Math.random() * 1296).toString(36),
                        code: hwSection.capFirstCode(),
                        action: pick,
                        command: pick === "custom" ? hwSection.customCommand.trim() : "",
                        enabled: true
                    }]));
                    hwSection.customCommand = "";
                    hwSection.capState = "idle";
                    hwSection.capEvents = [];
                }
            }
        }
    }
}
}
