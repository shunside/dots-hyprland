pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.common
import qs.modules.common.functions

/**
 * Reconciles generated Hyprland input state with config.json intent:
 * keyboard layout plus hardware-key mappings.
 * The scripts are idempotent and never touch hand-made files.
 */
Singleton {
    id: root

    function reconcile() {
        reconcileProc.running = true;
        hwkeysProc.running = true;
    }

    Process {
        id: reconcileProc
        command: [FileUtils.trimFileProtocol(`${Directories.scriptPath}/hyprland/input-layout-apply`), "--apply"]
    }

    Process {
        id: hwkeysProc
        command: [FileUtils.trimFileProtocol(`${Directories.scriptPath}/hyprland/hwkeys-apply`), "--apply"]
    }
}
