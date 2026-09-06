import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets

ContentPage {
    id: root
    forceWidth: true

    // Draft only: nothing here touches Config.options.input until Apply.
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
            if (exitCode === 0) {
                Config.options.input.layout = root.draftLayout;
                Config.options.input.variant = root.draftVariant;
                Config.options.input.options = root.draftOptions;
                applyProc.command = [root.applyScript, "--apply",
                    "--layout", root.draftLayout, "--variant", root.draftVariant, "--options", root.draftOptions];
                applyProc.running = false;
                applyProc.running = true;
            } else {
                applyResult.text = validateCollector.text.trim() || Translation.tr("Invalid keyboard setup.");
            }
        }
    }

    Process {
        id: applyProc
        stdout: StdioCollector {
            id: applyCollector
        }
        onExited: (exitCode, exitStatus) => {
            if (exitCode === 0) {
                applyResult.text = (root.draftLayout === "" && root.draftVariant === "" && root.draftOptions === "")
                    ? Translation.tr("Cleared. Using stock keyboard.")
                    : Translation.tr("Applied.");
                reloadProc.running = true;
            } else {
                applyResult.text = applyCollector.text.trim() || Translation.tr("Apply failed.");
            }
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
}
