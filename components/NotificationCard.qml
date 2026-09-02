// Notification card. Pure presentational — no service, Notification, or
// ListModel references. The popup container drives lifetime; the history
// panel drives static rendering. Both use the same component.

import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "../NotificationLogic.js" as NotificationLogic

BorderSurface {
  id: root

  property string app: ""
  property string appIcon: ""
  property string summary: ""
  property string body: ""
  property string image: ""
  // Nerd Font glyph rendered in the icon slot when no real icon is set.
  // Used by omarchy-notification-send so user-action toasts (`Silenced
  // notifications` etc.) show their bell/lock/etc. glyph without leaking
  // into the summary text.
  property string glyph: ""
  property string channel: ""
  // NotificationUrgency: Low=0, Normal=1, Critical=2 (upstream).
  property int urgency: 1
  property double timestamp: 0
  property int cornerRadius: 0

  // System monospace font injected by the container.
  property string fontFamily: ""

  readonly property bool hovered: hoverTracker.hovered

  signal closeRequested()
  signal cardClicked()
  // Prefer per-notification media/avatar data, then fall back to the app icon.
  // The `check` flag avoids Qt's missing-texture placeholder for unknown names.
  readonly property string smallIconSource: image.length > 0 ? NotificationLogic.validateImageSource(image) : iconSource(appIcon)
  readonly property bool hasGlyph: glyph.length > 0
  readonly property bool compactGlyph: NotificationLogic.shouldRenderCompactGlyph(glyph, smallIconSource, singleLineToast)
  readonly property bool hasSmallIcon: smallIconSource.length > 0
  readonly property bool summaryStartsWithGlyph: NotificationLogic.summaryStartsWithGlyph(summary)
  readonly property bool singleLineToast: sanitizedBody.length === 0
  readonly property bool collapseRedundantIcon: singleLineToast && !hasGlyph && summaryStartsWithGlyph
  readonly property string sanitizedBody: sanitizeBody(body)

  readonly property var otpData: NotificationLogic.extractOtp(summary, sanitizedBody)
  readonly property string otpCode: otpData ? otpData.code : ""
  readonly property string otpDisplay: otpData ? (otpData.raw || otpData.code) : ""
  property bool otpEnabled: true
  property bool copiedOtp: false
  signal otpCopied(string code)

  readonly property color dimColor: Qt.darker(Color.notifications.text, 1.4)
  readonly property color bodyColor: Qt.darker(Color.notifications.text, 1.15)
  readonly property color accentColor: urgency === 2 ? Color.urgent : (urgency === 0 ? dimColor : Color.notifications.countdown)
  readonly property var cardBorderSpec: Border.surfaceSpec("notifications", "border", Color.notifications.border, Math.max(1, Style.space(2)))

  function sanitizeBody(s) {
    return NotificationLogic.sanitizeBody(s, app, appIcon)
  }

  function iconSource(icon) {
    var value = String(icon || "")
    if (value.length === 0) return ""
    var validated = NotificationLogic.validateImageSource(value)
    if (!validated) return ""
    if (validated.indexOf("file://") === 0 || validated.indexOf("image://") === 0) return validated
    if (validated.charAt(0) === "/") return Util.fileUrl(validated)
    return Quickshell.iconPath(validated, true)
  }

  implicitWidth: Style.space(380)
  // Add vertical border insets so mainColumn (inset by border on top/left/right)
  // doesn't push content under the bottom edge.
  implicitHeight: mainColumn.implicitHeight + borderTop + borderBottom
  radius: cornerRadius
  color: Color.notifications.background
  borderSpec: cardBorderSpec
  clip: true

  HoverHandler { id: hoverTracker }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onClicked: function(mouse) {
      if (mouse.button === Qt.RightButton) {
        root.closeRequested()
      } else {
        root.cardClicked()
      }
    }
  }

  ColumnLayout {
    id: mainColumn
    z: 1
    // Inset by the card border so the content doesn't paint over the card's
    // outer border.
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.topMargin: root.borderTop
    anchors.leftMargin: root.borderLeft
    anchors.rightMargin: root.borderRight
    spacing: 0

    // Text content.
    RowLayout {
      Layout.fillWidth: true
      Layout.leftMargin: Style.space(12)
      Layout.rightMargin: Style.space(12)
      Layout.topMargin: root.singleLineToast ? Style.space(7) : Style.space(10)
      Layout.bottomMargin: root.singleLineToast ? Style.space(7) : Style.space(10)
      spacing: root.collapseRedundantIcon ? 0 : (root.compactGlyph ? Style.space(8) : Style.space(12))

      Item {
        id: smallIconSlot
        Layout.preferredWidth: visible ? Style.space(40) : 0
        Layout.preferredHeight: visible ? Style.space(40) : 0
        Layout.alignment: Qt.AlignVCenter
        // Hide the slot when the icon failed to resolve (themed-icon name
        // not in the user's icon theme) AND we don't have a glyph fallback
        // — prevents rendering Qt's pink broken-image placeholder.
        visible: !root.collapseRedundantIcon && !root.compactGlyph && (root.hasSmallIcon || root.hasGlyph) && (root.hasGlyph || smallIconImage.status !== Image.Error)

        Image {
          id: smallIconImage
          anchors.fill: parent
          source: root.smallIconSource
          sourceSize.width: smallIconSlot.width * Screen.devicePixelRatio
          sourceSize.height: smallIconSlot.height * Screen.devicePixelRatio
          fillMode: Image.PreserveAspectFit
          asynchronous: true
          smooth: true
          visible: !root.hasGlyph || smallIconImage.status === Image.Ready
        }

        // Glyph fallback (Nerd Font character) when no image icon is
        // available. Used by omarchy-notification-send's `-g` flag.
        Text {
          anchors.centerIn: parent
          visible: root.hasGlyph && smallIconImage.status !== Image.Ready
          text: root.glyph
          textFormat: Text.PlainText
          color: Color.notifications.text
          font.family: root.fontFamily
          font.pixelSize: Style.font.displayLarge
        }
      }

      Text {
        Layout.alignment: Qt.AlignVCenter
        visible: root.compactGlyph
        text: root.glyph
        textFormat: Text.PlainText
        color: Color.notifications.text
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
      }

      ColumnLayout {
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignVCenter
        spacing: Style.space(2)

        // App & Channel / Group breadcrumb
        RowLayout {
          Layout.fillWidth: true
          visible: root.channel.length > 0 || (root.app.length > 0 && root.app.toLowerCase() !== root.summary.toLowerCase())
          spacing: Style.space(6)

          Text {
            visible: root.app.length > 0 && root.app.toLowerCase() !== root.summary.toLowerCase()
            text: root.app
            textFormat: Text.PlainText
            font.family: "Liberation Sans"
            font.pixelSize: Style.font.caption
            font.bold: true
            color: root.dimColor
            elide: Text.ElideRight
          }

          Text {
            visible: (root.app.length > 0 && root.app.toLowerCase() !== root.summary.toLowerCase()) && root.channel.length > 0
            text: "·"
            textFormat: Text.PlainText
            font.family: "Liberation Sans"
            font.pixelSize: Style.font.caption
            color: root.dimColor
          }

          Rectangle {
            visible: root.channel.length > 0
            Layout.preferredHeight: Style.space(18)
            Layout.preferredWidth: channelLabel.implicitWidth + Style.space(12)
            radius: Style.space(4)
            color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18)
            border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.45)
            border.width: 1

            Text {
              id: channelLabel
              anchors.centerIn: parent
              text: root.channel
              textFormat: Text.PlainText
              font.family: "Liberation Sans"
              font.pixelSize: Style.font.caption
              font.bold: true
              color: Color.accent
              elide: Text.ElideRight
            }
          }
        }

        Text {
          Layout.fillWidth: true
          visible: root.summary.length > 0
          text: root.summary
          textFormat: Text.PlainText
          font.family: "Liberation Sans"
          color: Color.notifications.text
          font.pixelSize: Style.font.title
          font.bold: true
          wrapMode: Text.WordWrap
          elide: Text.ElideRight
          maximumLineCount: 2
        }

        Text {
          Layout.fillWidth: true
          Layout.topMargin: Style.space(2)
          visible: root.sanitizedBody.length > 0
          text: root.sanitizedBody
          textFormat: Text.PlainText
          font.family: "Liberation Sans"
          color: root.bodyColor
          font.pixelSize: Style.font.title
          wrapMode: Text.WordWrap
          elide: Text.ElideRight
          maximumLineCount: 3
        }
      }
    }

    // OTP / 2FA 1-Click Copy action button
    Item {
      z: 10
      Layout.fillWidth: true
      Layout.preferredHeight: Style.space(34)
      Layout.leftMargin: Style.space(12)
      Layout.rightMargin: Style.space(12)
      Layout.bottomMargin: Style.space(10)
      visible: root.otpCode.length > 0 && root.otpEnabled

      Rectangle {
        id: otpButtonRect
        anchors.fill: parent
        radius: Style.space(6)
        color: otpArea.containsPress ? Qt.darker(Color.accent, 1.3) : (otpArea.containsMouse ? Color.accent : Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.16))
        border.color: Color.accent
        border.width: 1

        RowLayout {
          anchors.centerIn: parent
          spacing: Style.space(6)

          Text {
            text: root.copiedOtp ? "✓" : "📋"
            textFormat: Text.PlainText
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            color: otpArea.containsMouse ? Color.background : Color.accent
          }

          Text {
            text: root.copiedOtp ? "Copied to Clipboard!" : ("Copy Code: " + root.otpDisplay)
            textFormat: Text.PlainText
            font.family: "Liberation Sans"
            font.pixelSize: Style.font.body
            font.bold: true
            color: otpArea.containsMouse ? Color.background : Color.notifications.text
          }
        }

        MouseArea {
          id: otpArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          acceptedButtons: Qt.LeftButton
          onClicked: function(mouse) {
            mouse.accepted = true
            root.copiedOtp = true
            Util.execDetached("printf %s " + Util.shellQuote(root.otpCode) + " | wl-copy")
            root.otpCopied(root.otpCode)
            otpResetTimer.restart()
          }
        }

        Timer {
          id: otpResetTimer
          interval: 2000
          onTriggered: root.copiedOtp = false
        }
      }
    }
  }

}
