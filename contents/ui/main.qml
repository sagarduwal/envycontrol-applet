// SPDX-License-Identifier: GPL-2.0-or-later

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.plasma.plasmoid
import org.kde.plasma.plasma5support as Plasma5Support

PlasmoidItem {
    id: root

    readonly property var allowedModes: ["integrated", "hybrid", "nvidia"]
    readonly property var modes: [
        {
            id: "integrated",
            title: i18n("Integrated"),
            detail: i18n("NVIDIA GPU powered off"),
            icon: "computer-laptop",
            tint: "#3d8bfd"
        },
        {
            id: "hybrid",
            title: i18n("Hybrid"),
            detail: i18n("NVIDIA GPU only when an app asks for it"),
            icon: "preferences-desktop-display",
            tint: "#e6a317"
        },
        {
            id: "nvidia",
            title: i18n("Nvidia"),
            detail: i18n("Writes EnvyControl's X11 config. This Wayland session stays on the Intel GPU."),
            icon: "show-gpu-effects",
            tint: "#3cba6c"
        }
    ]

    property string currentMode: ""
    property string selectedMode: ""
    property bool busy: false
    property string statusText: ""
    property string statusDetail: ""
    property bool detailsOpen: false
    property bool statusIsError: false
    property string pendingKind: ""
    property string activeSource: ""
    property string pollSource: ""
    property string progressText: ""
    property bool envycontrolMissing: false
    property bool installThenSwitch: false

    readonly property string switchLog: "/tmp/envycontrol-applet.log"

    readonly property bool canApply: !busy
        && !envycontrolMissing
        && currentMode !== ""
        && allowedModes.indexOf(selectedMode) !== -1
        && selectedMode !== currentMode

    toolTipMainText: i18n("EnvyControl")
    toolTipSubText: currentMode === "" ? i18n("Graphics mode") : i18n("Graphics: %1", modeTitle(currentMode))

    switchWidth: Kirigami.Units.gridUnit * 16
    switchHeight: Kirigami.Units.gridUnit * 12
    hideOnWindowDeactivate: !busy

    function modeTitle(mode) {
        for (let i = 0; i < modes.length; ++i) {
            if (modes[i].id === mode)
                return modes[i].title
        }
        return mode
    }

    function clip(text) {
        if (text.length <= 4000)
            return text
        return text.slice(text.length - 4000)
    }

    function commandOutput(data) {
        const stdout = (data["stdout"] || "").toString().trim()
        const stderr = (data["stderr"] || "").toString().trim()
        if (stdout !== "" && stderr !== "")
            return clip(stdout + "\n" + stderr)
        return clip(stdout || stderr)
    }

    function exitCode(data) {
        const code = data["exit code"]
        if (code === undefined || code === null)
            return -1
        return Number(code)
    }

    function parseMode(stdout) {
        const lines = stdout.toString().trim().split("\n").map(line => line.trim()).filter(line => line.length > 0)
        if (lines.length === 0)
            return ""
        return lines[lines.length - 1]
    }

    function queryCommand() {
        return "/usr/bin/envycontrol --query # " + Date.now()
    }

    function installCommand() {
        return "if [ ! -x /usr/bin/paru ]; then echo 'paru is not installed. Install paru, then install EnvyControl.' >&2; exit 1; fi; "
            + "SUDO_ASKPASS=/usr/bin/ksshaskpass /usr/bin/paru -S --noconfirm --needed --sudoflags --askpass envycontrol # "
            + Date.now()
    }

    function missingEnvyControl(code, output) {
        if (code === 127)
            return true
        const lower = output.toLowerCase()
        return lower.indexOf("not found") !== -1 || lower.indexOf("no such file") !== -1
    }

    function switchCommand(mode) {
        if (allowedModes.indexOf(mode) === -1)
            return ""
        const log = switchLog
        return "pkexec /bin/sh -c \"umask 022; : > " + log
            + "; /usr/bin/script -q -e -f -c 'PYTHONUNBUFFERED=1 /usr/bin/envycontrol --switch " + mode
            + " --verbose && /usr/bin/limine-mkinitcpio' " + log + "\" # " + Date.now()
    }

    function formatProgress(raw) {
        const lines = raw.toString().split("\n")
        const cleaned = []
        for (let i = 0; i < lines.length; ++i) {
            let line = lines[i]
            const cr = line.lastIndexOf("\r")
            if (cr !== -1)
                line = line.slice(cr + 1)
            line = line.replace(/\u001b\[[0-9;]*[A-Za-z]/g, "").trim()
            if (line.length === 0)
                continue
            if (line.indexOf("Script started on") === 0)
                continue
            if (line.indexOf("Script done on") === 0)
                continue
            cleaned.push(line)
        }
        if (cleaned.length <= 40)
            return cleaned.join("\n")
        return cleaned.slice(cleaned.length - 40).join("\n")
    }

    function pollLog() {
        if (pollSource !== "" || pendingKind !== "switch")
            return
        const command = "/bin/cat " + switchLog + " # " + Date.now()
        pollSource = command
        execEngine.connectSource(command)
    }

    function launch(command, kind) {
        if (command === "")
            return
        pendingKind = kind
        activeSource = command
        busy = true
        if (kind === "switch" || kind === "install") {
            statusIsError = false
            statusDetail = ""
            detailsOpen = false
            progressText = ""
            statusText = kind === "install" ? i18n("Installing EnvyControl…") : ""
        }
        execEngine.connectSource(command)
    }

    function startInstall(fromMode) {
        if (busy)
            return
        installThenSwitch = fromMode
        launch(installCommand(), "install")
    }

    function refresh() {
        launch(queryCommand(), "query")
    }

    function startSwitch() {
        const command = switchCommand(selectedMode)
        if (command === "")
            return
        launch(command, "switch")
    }

    function authenticationCancelled(code, output) {
        if (code === 126)
            return true
        const lower = output.toLowerCase()
        return lower.indexOf("dismissed") !== -1
            || lower.indexOf("not authorized") !== -1
            || lower.indexOf("no password was provided") !== -1
            || lower.indexOf("a password is required") !== -1
    }

    function applyQuery(stdout) {
        const mode = parseMode(stdout)
        if (allowedModes.indexOf(mode) === -1) {
            busy = false
            if (pendingKind === "query") {
                statusIsError = true
                statusText = i18n("Could not read the graphics mode.")
            }
            return
        }
        envycontrolMissing = false
        currentMode = mode
        selectedMode = mode
        busy = false
        if (pendingKind === "query") {
            statusIsError = false
            statusText = ""
        }
    }

    function finishInstalledQuery(stdout) {
        const mode = parseMode(stdout)
        const chosen = selectedMode
        const offerSwitch = installThenSwitch
        installThenSwitch = false
        envycontrolMissing = false
        busy = false
        if (allowedModes.indexOf(mode) === -1) {
            statusIsError = true
            statusText = i18n("EnvyControl installed, but the graphics mode could not be read.")
            return
        }
        currentMode = mode
        statusIsError = false
        if (offerSwitch && allowedModes.indexOf(chosen) !== -1 && chosen !== mode) {
            selectedMode = chosen
            statusText = i18n("EnvyControl installed.")
            confirmDialog.open()
            return
        }
        selectedMode = mode
        statusText = i18n("EnvyControl installed.")
    }

    function handleResult(data) {
        const code = exitCode(data)
        const output = commandOutput(data)
        const kind = pendingKind

        if (kind === "query" || kind === "query-keep" || kind === "query-after-install") {
            if (code !== 0) {
                busy = false
                if (missingEnvyControl(code, output)) {
                    envycontrolMissing = true
                    currentMode = ""
                    statusIsError = false
                    statusText = ""
                    statusDetail = ""
                    return
                }
                statusIsError = true
                if (kind === "query" || kind === "query-after-install")
                    statusText = output || i18n("Could not read the graphics mode.")
                return
            }
            if (kind === "query-after-install")
                finishInstalledQuery(data["stdout"] || "")
            else
                applyQuery(data["stdout"] || "")
            return
        }

        if (kind === "install") {
            if (authenticationCancelled(code, output)) {
                busy = false
                installThenSwitch = false
                statusIsError = true
                statusText = i18n("Authentication cancelled.")
                return
            }
            if (code !== 0) {
                busy = false
                installThenSwitch = false
                statusIsError = true
                statusDetail = output.length > 160 ? output : ""
                statusText = statusDetail === "" ? (output || i18n("Install failed.")) : i18n("Install failed.")
                detailsOpen = false
                return
            }
            statusIsError = false
            statusDetail = ""
            statusText = ""
            launch(queryCommand(), "query-after-install")
            return
        }

        if (kind !== "switch") {
            busy = false
            return
        }

        if (authenticationCancelled(code, output)) {
            busy = false
            statusIsError = true
            statusText = i18n("Authentication cancelled.")
            selectedMode = currentMode
            return
        }

        if (code !== 0) {
            statusIsError = true
            statusDetail = output.length > 160 ? output : ""
            statusText = statusDetail === "" ? (output || i18n("Switch failed.")) : i18n("Switch failed.")
            detailsOpen = false
            launch(queryCommand(), "query-keep")
            return
        }

        statusIsError = false
        statusDetail = ""
        detailsOpen = false
        statusText = i18n("Set to %1. Reboot to apply.", modeTitle(selectedMode))
        launch(queryCommand(), "query-keep")
    }

    Component.onCompleted: refresh()

    onExpandedChanged: function(expanded) {
        if (expanded && root.currentMode === "" && !root.busy)
            root.refresh()
    }

    compactRepresentation: MouseArea {
        id: compactMouse

        implicitWidth: Kirigami.Units.iconSizes.smallMedium
        implicitHeight: Kirigami.Units.iconSizes.smallMedium
        hoverEnabled: true
        onClicked: root.expanded = !root.expanded

        Kirigami.Icon {
            anchors.fill: parent
            source: "show-gpu-effects"
            active: compactMouse.containsMouse || root.expanded
        }
    }

    fullRepresentation: PlasmaExtras.Representation {
        id: fullRep

        collapseMarginsHint: false
        implicitWidth: Kirigami.Units.gridUnit * 22
        implicitHeight: heading.implicitHeight + contentColumn.childrenRect.height
        Layout.minimumWidth: Kirigami.Units.gridUnit * 20
        Layout.preferredWidth: Kirigami.Units.gridUnit * 22
        Layout.minimumHeight: implicitHeight
        Layout.maximumHeight: implicitHeight
        Layout.preferredHeight: implicitHeight

        header: PlasmaExtras.PlasmoidHeading {
            id: heading
            contentItem: RowLayout {
                PlasmaExtras.Heading {
                    level: 3
                    text: i18n("Graphics")
                }

                Item {
                    Layout.fillWidth: true
                }

                PlasmaComponents.BusyIndicator {
                    visible: root.busy
                    running: root.busy
                    Layout.preferredWidth: Kirigami.Units.iconSizes.small
                    Layout.preferredHeight: Kirigami.Units.iconSizes.small
                }
            }
        }

        contentItem: Column {
            id: contentColumn

            spacing: Kirigami.Units.smallSpacing
            width: parent ? parent.width : implicitWidth

            Repeater {
                model: root.modes

                delegate: MouseArea {
                    id: modeRow

                    required property var modelData

                    readonly property bool chosen: root.selectedMode === modelData.id
                    readonly property bool inUse: root.currentMode === modelData.id

                    width: contentColumn.width
                    height: modeRowLayout.implicitHeight + Kirigami.Units.smallSpacing * 2
                    hoverEnabled: true
                    enabled: !root.busy && (root.currentMode !== "" || root.envycontrolMissing)
                    onClicked: {
                        root.selectedMode = modelData.id
                        if (root.envycontrolMissing)
                            root.startInstall(true)
                    }

                    Rectangle {
                        anchors.fill: parent
                        radius: Kirigami.Units.smallSpacing
                        visible: modeRow.inUse
                        color: modeRow.containsMouse || modeRow.chosen
                            ? Qt.rgba(0.95, 0.28, 0.28, 0.42)
                            : Qt.rgba(0.95, 0.35, 0.35, 0.24)
                        border.width: 1
                        border.color: Qt.rgba(1, 0.55, 0.55, 0.85)
                    }

                    PlasmaExtras.Highlight {
                        anchors.fill: parent
                        visible: !modeRow.inUse && (modeRow.chosen || modeRow.containsMouse)
                        hovered: modeRow.containsMouse
                        pressed: modeRow.pressed
                        active: modeRow.chosen
                    }

                    RowLayout {
                        id: modeRowLayout

                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: Kirigami.Units.smallSpacing
                        anchors.rightMargin: Kirigami.Units.smallSpacing
                        spacing: Kirigami.Units.mediumSpacing

                        Rectangle {
                            Layout.alignment: Qt.AlignVCenter
                            Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                            Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                            radius: Kirigami.Units.smallSpacing
                            color: modeRow.modelData.tint

                            Kirigami.Icon {
                                anchors.centerIn: parent
                                width: Kirigami.Units.iconSizes.small
                                height: Kirigami.Units.iconSizes.small
                                source: modeRow.modelData.icon
                                isMask: true
                                color: "white"
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.smallSpacing

                                PlasmaComponents.Label {
                                    text: modeRow.modelData.title
                                    font.weight: modeRow.chosen ? Font.DemiBold : Font.Normal
                                }

                                Rectangle {
                                    visible: modeRow.inUse
                                    radius: height / 2
                                    color: Qt.rgba(0.92, 0.32, 0.32, 0.95)
                                    implicitWidth: inUseLabel.implicitWidth + Kirigami.Units.smallSpacing * 2
                                    implicitHeight: inUseLabel.implicitHeight + Kirigami.Units.smallSpacing

                                    PlasmaComponents.Label {
                                        id: inUseLabel
                                        anchors.centerIn: parent
                                        text: i18n("In use")
                                        font: Kirigami.Theme.smallFont
                                        color: "white"
                                    }
                                }
                            }

                            PlasmaComponents.Label {
                                Layout.fillWidth: true
                                text: modeRow.modelData.detail
                                opacity: 0.7
                                wrapMode: Text.WordWrap
                                font: Kirigami.Theme.smallFont
                            }
                        }

                        Kirigami.Icon {
                            source: "checkmark"
                            isMask: true
                            color: Kirigami.Theme.textColor
                            visible: modeRow.chosen && !modeRow.inUse
                            Layout.preferredWidth: Kirigami.Units.iconSizes.small
                            Layout.preferredHeight: Kirigami.Units.iconSizes.small
                        }
                    }
                }
            }

            Kirigami.InlineMessage {
                width: contentColumn.width
                height: visible ? implicitHeight : 0
                visible: root.statusText !== ""
                text: root.statusText
                type: root.statusIsError ? Kirigami.MessageType.Error : Kirigami.MessageType.Positive
            }

            PlasmaComponents.Button {
                width: contentColumn.width
                height: visible ? implicitHeight : 0
                visible: root.statusDetail !== ""
                flat: true
                text: root.detailsOpen ? i18n("Hide details") : i18n("Show details")
                icon.name: root.detailsOpen ? "arrow-up" : "arrow-down"
                onClicked: root.detailsOpen = !root.detailsOpen
            }

            PlasmaComponents.TextArea {
                width: contentColumn.width
                height: visible ? Kirigami.Units.gridUnit * 5 : 0
                visible: root.detailsOpen && root.statusDetail !== ""
                readOnly: true
                wrapMode: TextEdit.Wrap
                text: root.statusDetail
                background: null
            }

            Column {
                width: contentColumn.width
                visible: root.busy && root.pendingKind === "switch"
                height: visible ? implicitHeight : 0
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents.Label {
                    width: parent.width
                    text: i18n("Switching to %1…", root.modeTitle(root.selectedMode))
                    font.weight: Font.DemiBold
                    wrapMode: Text.WordWrap
                }

                PlasmaComponents.TextArea {
                    id: progressLog

                    width: parent.width
                    height: Kirigami.Units.gridUnit * 8
                    readOnly: true
                    wrapMode: TextEdit.Wrap
                    selectByMouse: true
                    text: root.progressText === ""
                        ? i18n("Waiting for authentication…")
                        : root.progressText
                    font.family: "monospace"
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    background: null
                    onTextChanged: cursorPosition = length
                }
            }

            PlasmaComponents.Label {
                width: contentColumn.width
                visible: !root.envycontrolMissing && !root.canApply && !root.busy && root.statusText === ""
                text: root.currentMode === ""
                    ? i18n("Reading the current mode…")
                    : i18n("Choose another mode. It takes effect after reboot.")
                opacity: 0.7
                wrapMode: Text.WordWrap
                font: Kirigami.Theme.smallFont
            }

            PlasmaComponents.Button {
                width: contentColumn.width
                height: visible ? implicitHeight : 0
                visible: root.envycontrolMissing && !root.busy
                icon.name: "install"
                text: i18n("Install EnvyControl")
                onClicked: root.startInstall(false)
            }

            PlasmaComponents.Button {
                width: contentColumn.width
                height: visible ? implicitHeight : 0
                visible: root.canApply || (root.busy && root.pendingKind === "switch")
                enabled: root.canApply
                icon.name: "system-reboot"
                text: i18n("Switch to %1", root.modeTitle(root.selectedMode))
                onClicked: confirmDialog.open()
            }
        }
    }

    Kirigami.PromptDialog {
        id: confirmDialog

        title: i18n("Switch graphics mode")
        subtitle: i18n("Switch to %1? This takes effect after reboot.", root.modeTitle(root.selectedMode))
        standardButtons: Kirigami.Dialog.NoButton
        customFooterActions: [
            Kirigami.Action {
                text: i18n("Switch")
                icon.name: "dialog-ok"
                onTriggered: {
                    confirmDialog.close()
                    root.startSwitch()
                }
            },
            Kirigami.Action {
                text: i18n("Cancel")
                icon.name: "dialog-cancel"
                onTriggered: confirmDialog.close()
            }
        ]
    }

    Plasma5Support.DataSource {
        id: execEngine

        engine: "executable"
        connectedSources: []

        onNewData: (sourceName, data) => {
            if (sourceName === root.pollSource) {
                disconnectSource(sourceName)
                root.pollSource = ""
                if (root.pendingKind === "switch") {
                    const formatted = root.formatProgress(data["stdout"] || "")
                    if (formatted !== "")
                        root.progressText = formatted
                }
                return
            }
            if (sourceName !== root.activeSource)
                return
            disconnectSource(sourceName)
            root.activeSource = ""
            root.handleResult(data)
        }
    }

    Timer {
        interval: 400
        repeat: true
        running: root.busy && root.pendingKind === "switch"
        onTriggered: root.pollLog()
    }
}
