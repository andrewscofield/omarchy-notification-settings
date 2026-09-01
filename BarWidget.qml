import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "andrew.notifications"

  readonly property var service: bar && bar.shell
    ? (bar.shell.serviceFor(root.moduleName) || bar.shell.serviceFor("andrew.notifications") || bar.shell.serviceFor("omarchy-notifications-settings") || bar.shell.firstPartyServiceFor("omarchy.notifications"))
    : null
  readonly property bool isCenter: root.region === "center"
  readonly property bool centerHovered: bar && bar.centerSectionRevealHeld === true && bar.centerHoverRevealSuppressed !== true
  readonly property bool isDnd: service ? service.doNotDisturb : false
  readonly property bool panelOpen: panelLoader.item ? panelLoader.item.open : false
  readonly property bool revealed: !isCenter || hovered || panelOpen || centerHovered || isDnd

  implicitWidth: revealed ? Style.bar.statusSlot : 0
  implicitHeight: Style.bar.statusSlot
  visible: true
  clip: true

  Behavior on implicitWidth { NumberAnimation { duration: 120 } }
  Behavior on opacity { NumberAnimation { duration: 120 } }
  opacity: panelOpen ? 1.0 : (hovered ? 1.0 : (revealed ? (isCenter ? 0.45 : 1.0) : 0.0))

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.isDnd ? "󰂛" : "󰂚"
    tooltipText: root.isDnd ? "Notifications Muted · Right-click to unmute" : "Notification Settings"
    useActiveColor: root.isDnd
    activeColor: Color.urgent
    active: root.isDnd

    onPressed: function(btn) {
      if (btn === Qt.RightButton) {
        if (root.service) root.service.setDoNotDisturb(!root.service.doNotDisturb)
      } else {
        root.togglePanel()
      }
    }
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.open === true : false

  function toggle() {
    opened ? close() : open()
  }

  function togglePanel() {
    toggle()
  }

  function open() {
    if (panelLoader.item) panelLoader.item.open = true
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  Loader {
    id: panelLoader
    active: true
    sourceComponent: panelComponent
  }

  Component {
    id: panelComponent
    NotificationSettingsPanel {
      anchorItem: button
      bar: root.bar
      owner: root
    }
  }
}
