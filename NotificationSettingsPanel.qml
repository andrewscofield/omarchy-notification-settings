import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

KeyboardPanel {
  id: root

  property var service: bar && bar.shell ? bar.shell.serviceFor("andrew.notifications") : null
  property bool previewSent: false

  centerOnBar: true
  focusTarget: keyCatcher
  contentWidth: fittedContentWidth(Style.space(420))
  contentHeight: fittedContentHeight(mainColumn.implicitHeight)

  PanelKeyCatcher {
    id: keyCatcher
    anchors.fill: parent
    onCloseRequested: root.close()

    ColumnLayout {
      id: mainColumn
      width: parent.width
      spacing: Style.space(12)

      // ------------------------------------------------ Header
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(10)

        Rectangle {
          Layout.preferredWidth: Style.space(36)
          Layout.preferredHeight: Style.space(36)
          radius: Style.cornerRadius
          color: (root.service && root.service.doNotDisturb)
            ? Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.18)
            : Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18)
          border.color: (root.service && root.service.doNotDisturb) ? Color.urgent : Color.accent
          border.width: 1

          Text {
            anchors.centerIn: parent
            text: (root.service && root.service.doNotDisturb) ? "󰂛" : "󰂚"
            font.family: Style.font.family
            font.pixelSize: Style.font.iconLarge
            color: (root.service && root.service.doNotDisturb) ? Color.urgent : Color.accent
          }
        }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(2)

          Text {
            text: "Notification Settings"
            font.family: Style.font.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
            color: Color.foreground
          }

          Text {
            text: (root.service && root.service.doNotDisturb)
              ? "Do Not Disturb (Alerts silenced)"
              : ((root.service ? root.service.popupModel.count : 0) + " alerts on screen")
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: (root.service && root.service.doNotDisturb) ? Color.urgent : Color.muted
          }
        }

        // Quick DND Toggle Switch
        RowLayout {
          spacing: Style.space(6)
          Text {
            text: "DND"
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
            color: (root.service && root.service.doNotDisturb) ? Color.urgent : Color.muted
          }
          ToggleSwitch {
            checked: root.service ? root.service.doNotDisturb : false
            onToggled: if (root.service) root.service.setDoNotDisturb(!root.service.doNotDisturb)
          }
        }
      }

      PanelSeparator {}

      // ------------------------------------------------ Position Section
      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)

        PanelSectionHeader {
          text: "SCREEN POSITION"
        }

        // Top positions (3)
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          readonly property var topPositions: [
            { id: "top-left", label: "Top Left" },
            { id: "top-center", label: "Top Center" },
            { id: "top-right", label: "Top Right" }
          ]

          Repeater {
            model: parent.topPositions

            Item {
              required property var modelData
              Layout.fillWidth: true
              Layout.preferredHeight: Style.space(32)

              readonly property bool isSelected: root.service ? root.service.position === modelData.id : (modelData.id === "bottom-center")

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                color: isSelected
                  ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.2)
                  : (topPosMouse.containsMouse ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.08) : "transparent")
                border.color: isSelected ? Color.accent : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.2)
                border.width: isSelected ? 1.5 : 1

                Text {
                  anchors.centerIn: parent
                  text: modelData.label
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: isSelected
                  color: isSelected ? Color.accent : Color.foreground
                }

                MouseArea {
                  id: topPosMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: if (root.service) root.service.setPosition(modelData.id)
                }
              }
            }
          }
        }

        // Bottom positions (3)
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          readonly property var bottomPositions: [
            { id: "bottom-left", label: "Bottom Left" },
            { id: "bottom-center", label: "Bottom Center" },
            { id: "bottom-right", label: "Bottom Right" }
          ]

          Repeater {
            model: parent.bottomPositions

            Item {
              required property var modelData
              Layout.fillWidth: true
              Layout.preferredHeight: Style.space(32)

              readonly property bool isSelected: root.service ? root.service.position === modelData.id : (modelData.id === "bottom-center")

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                color: isSelected
                  ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.2)
                  : (botPosMouse.containsMouse ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.08) : "transparent")
                border.color: isSelected ? Color.accent : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.2)
                border.width: isSelected ? 1.5 : 1

                Text {
                  anchors.centerIn: parent
                  text: modelData.label
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: isSelected
                  color: isSelected ? Color.accent : Color.foreground
                }

                MouseArea {
                  id: botPosMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: if (root.service) root.service.setPosition(modelData.id)
                }
              }
            }
          }
        }
      }

      // ------------------------------------------------ Timeout Section
      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)

        PanelSectionHeader {
          text: "DISPLAY TIMEOUT"
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          readonly property var durations: [ 3, 5, 8, 12, 15 ]

          Repeater {
            model: parent.durations

            Item {
              required property int modelData
              Layout.fillWidth: true
              Layout.preferredHeight: Style.space(30)

              readonly property bool isSelected: root.service ? root.service.timeoutSeconds === modelData : (modelData === 8)

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                color: isSelected
                  ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.2)
                  : (durMouse.containsMouse ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.08) : "transparent")
                border.color: isSelected ? Color.accent : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.2)
                border.width: isSelected ? 1.5 : 1

                Text {
                  anchors.centerIn: parent
                  text: modelData + "s"
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: isSelected
                  color: isSelected ? Color.accent : Color.foreground
                }

                MouseArea {
                  id: durMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: if (root.service) root.service.setTimeoutSeconds(modelData)
                }
              }
            }
          }
        }
      }

      PanelSeparator {}

      // ------------------------------------------------ Grouping Section
      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)

        PanelSectionHeader {
          text: "NOTIFICATION GROUPING"
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          readonly property var modes: [
            { id: "all", label: "All Alerts" },
            { id: "app", label: "1 Per App" },
            { id: "channel", label: "1 Per Channel" }
          ]

          Repeater {
            model: parent.modes

            Item {
              required property var modelData
              Layout.fillWidth: true
              Layout.preferredHeight: Style.space(32)

              readonly property bool isSelected: root.service ? root.service.groupingMode === modelData.id : (modelData.id === "channel")

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                color: isSelected
                  ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.2)
                  : (groupMouse.containsMouse ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.08) : "transparent")
                border.color: isSelected ? Color.accent : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.2)
                border.width: isSelected ? 1.5 : 1

                Text {
                  anchors.centerIn: parent
                  text: modelData.label
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: isSelected
                  color: isSelected ? Color.accent : Color.foreground
                }

                MouseArea {
                  id: groupMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: if (root.service) root.service.setGroupingMode(modelData.id)
                }
              }
            }
          }
        }

        Text {
          Layout.fillWidth: true
          Layout.topMargin: Style.space(2)
          text: {
            var mode = root.service ? root.service.groupingMode : "channel"
            if (mode === "all") return "Show all incoming toasts without deduplication."
            if (mode === "app") return "Keep 1 alert per app (newer replaces older from the same app)."
            return "Keep 1 alert per channel/conversation (#dev and #general stay separate)."
          }
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          color: Color.muted
          wrapMode: Text.WordWrap
        }
      }

      PanelSeparator {}

      // ------------------------------------------------ Toggles Section
      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)

        PanelSectionHeader {
          text: "BEHAVIOR & FEATURES"
        }

        Toggle {
          Layout.fillWidth: true
          label: "Extract 2FA / OTP Codes"
          description: "Adds 1-click clipboard copy button to verification messages"
          checked: root.service ? root.service.otpCopy : true
          onClicked: if (root.service) root.service.setOtpCopy(!root.service.otpCopy)
        }

        Toggle {
          Layout.fillWidth: true
          label: "Sticky Chat Alerts"
          description: "Keeps Slack, Signal, and messaging alerts visible until dismissed"
          checked: root.service ? root.service.infiniteChat : true
          onClicked: if (root.service) root.service.setInfiniteChat(!root.service.infiniteChat)
        }
      }

      PanelSeparator {}

      // ------------------------------------------------ Preview & Actions Section
      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        PanelSectionHeader {
          text: "PREVIEW & ACTIONS"
        }

        // Prominent Preview Button
        Item {
          Layout.fillWidth: true
          Layout.preferredHeight: Style.space(38)

          Rectangle {
            id: previewBtn
            anchors.fill: parent
            radius: Style.cornerRadius
            color: previewMouse.containsPress
              ? Qt.darker(Color.accent, 1.3)
              : (previewMouse.containsMouse ? Color.accent : Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.2))
            border.color: Color.accent
            border.width: 1.5

            RowLayout {
              anchors.centerIn: parent
              spacing: Style.space(8)

              Text {
                text: root.previewSent ? "✓" : "󰔎"
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
                color: previewMouse.containsMouse ? Color.background : Color.accent
              }

              Text {
                text: root.previewSent ? "Preview Notification Sent!" : "Preview Notification Toast"
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
                color: previewMouse.containsMouse ? Color.background : Color.foreground
              }
            }

            MouseArea {
              id: previewMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.previewSent = true
                Quickshell.execDetached([
                  "notify-send",
                  "-a", "Slack",
                  "-h", "string:x-kde-tag:channel_dev",
                  "Alice in #dev",
                  "G-492019 is your staging deploy verification code."
                ])
                previewResetTimer.restart()
              }
            }

            Timer {
              id: previewResetTimer
              interval: 2000
              onTriggered: root.previewSent = false
            }
          }
        }

        // Secondary Actions Row
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Item {
            Layout.fillWidth: true
            Layout.preferredHeight: Style.space(32)

            Rectangle {
              anchors.fill: parent
              radius: Style.cornerRadius
              color: clearMouse.containsMouse ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.1) : "transparent"
              border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.2)
              border.width: 1

              RowLayout {
                anchors.centerIn: parent
                spacing: Style.space(6)
                Text { text: "󰃢"; font.family: Style.font.family; color: Color.foreground; font.pixelSize: Style.font.caption }
                Text { text: "Clear Active"; font.family: Style.font.family; color: Color.foreground; font.pixelSize: Style.font.caption; font.bold: true }
              }

              MouseArea {
                id: clearMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: if (root.service) root.service.dismissAll()
              }
            }
          }

          Item {
            Layout.fillWidth: true
            Layout.preferredHeight: Style.space(32)

            Rectangle {
              anchors.fill: parent
              radius: Style.cornerRadius
              color: histMouse.containsMouse ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.1) : "transparent"
              border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.2)
              border.width: 1

              RowLayout {
                anchors.centerIn: parent
                spacing: Style.space(6)
                Text { text: ""; font.family: Style.font.family; color: Color.foreground; font.pixelSize: Style.font.caption }
                Text { text: "Open History"; font.family: Style.font.family; color: Color.foreground; font.pixelSize: Style.font.caption; font.bold: true }
              }

              MouseArea {
                id: histMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (root.service) root.service.showRecentHistory()
                  root.close()
                }
              }
            }
          }
        }
      }
    }
  }
}
