pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.common
import qs.modules.common.functions

/**
 * Reconciles generated Hyprland input state with config.json intent.
 * The script is idempotent and never touches hand-made files.
 */
Singleton {
    id: root

    function reconcile() {
        reconcileProc.running = true;
    }

    Process {
        id: reconcileProc
        command: [FileUtils.trimFileProtocol(`${Directories.scriptPath}/hyprland/input-layout-apply`), "--apply"]
    }
}
