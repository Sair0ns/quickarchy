import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import qs.Commons
import qs.Ui

// Full-screen file preview in the spirit of macOS Quick Look: one keypress in
// the file manager puts the file on screen, another dismisses it. All format
// handling lives in bin/quick-look-probe, which reports what to draw as JSON;
// this file only renders the result.
Item {
  id: root

  // Injected by the shell host.
  property var shell: null
  property var manifest: null

  property bool opened: false
  property bool loading: false
  property string requestedPath: ""
  property var info: ({})

  readonly property string probeScript: manifest && manifest.__sourceDir
    ? String(manifest.__sourceDir) + "/bin/quick-look-probe"
    : ""

  // Decode ceilings. Qt must rasterise whatever an Image is handed, so every
  // Image below carries a sourceSize; without it a single oversized file would
  // be decoded at full size inside the shared shell process.
  readonly property int maxPayloadBytes: 1024 * 1024
  readonly property int maxDecodeEdge: 2600

  readonly property string kind: String(info.kind || "")
  readonly property string displayName: String(info.name || "Quick Look")
  readonly property var previewImages: info.images instanceof Array ? info.images : []
  readonly property var previewEntries: info.entries instanceof Array ? info.entries : []

  readonly property var kindGlyphs: ({
    "image": "󰋩", "pdf": "󰈦", "video": "󰕧", "audio": "󰎆",
    "text": "󰈙", "markdown": "󰍔", "directory": "󰉋", "archive": "󰛫",
    "binary": "󰈔", "missing": "󰀦"
  })

  readonly property string kindGlyph: kindGlyphs[kind] !== undefined ? kindGlyphs[kind] : "󰈔"

  function shellQuote(v) {
    return "'" + String(v).replace(/'/g, "'\\''") + "'"
  }

  // Percent-encode each path segment. Qt parses the string as a URL, so a
  // literal '#' truncates at the fragment, '?' at the query, and '%' is decoded
  // — the last of which can resolve to a *different* file than the one picked.
  function fileUrl(path) {
    var parts = String(path || "").split("/")
    for (var i = 0; i < parts.length; i++) parts[i] = encodeURIComponent(parts[i])
    return "file://" + parts.join("/")
  }

  // Allowlist rather than denylist: anything not plainly a web link is ignored.
  function isSafeLink(link) {
    return /^(https?|mailto):/i.test(String(link || "").trim())
  }

  // Entry point used by `omarchy-shell shell summon andreconde.quick-look`.
  function open(payload) {
    var args = {}
    try { args = payload ? JSON.parse(String(payload)) : {} } catch (e) { args = {} }
    openFile(String(args.path || ""))
  }

  // Quickshell ignores a command change while a Process is running, so a second
  // request during a slow probe (a multi-page PDF) would be dropped and the
  // first file's content shown under the second file's name. Remember the newer
  // request, stop the in-flight probe, and run it when that one exits.
  property string pendingPath: ""

  function startProbe(target) {
    if (probe.running) {
      pendingPath = target
      probe.running = false
      return
    }
    startProbe(target)
  }

  function openFile(path) {
    var target = String(path || "")
    if (target === "") {
      info = {
        kind: "missing",
        name: "Quick Look",
        error: "No file selected.\n\nSelect a file in Files and press Space, or run:\nomarchy-shell shell summon andreconde.quick-look '{\"path\":\"/etc/hostname\"}'"
      }
      loading = false
      opened = true
      return
    }

    requestedPath = target
    loading = true
    opened = true
    if (probeScript === "") {
      info = { kind: "missing", name: target.split("/").pop(), error: "Preview helper not found." }
      loading = false
      return
    }
    probe.command = ["python3", probeScript, target]
    probe.running = true
  }

  function close() {
    opened = false
    loading = false
  }

  function toggle(payload) {
    if (opened) close()
    else open(payload)
  }

  // Same file asked for again while it is on screen: treat as dismiss, which
  // is what tapping Space twice in the file manager should do.
  function showOrDismiss(path) {
    if (opened && String(path) === requestedPath) { close(); return }
    openFile(path)
  }

  function openExternally() {
    if (requestedPath === "") return
    Quickshell.execDetached(["sh", "-lc", "xdg-open " + shellQuote(requestedPath) + " >/dev/null 2>&1 &"])
    close()
  }

  function metaLine() {
    var parts = []
    if (info.sizeHuman) parts.push(String(info.sizeHuman))
    var meta = info.meta instanceof Array ? info.meta : []
    for (var i = 0; i < meta.length; i++) parts.push(String(meta[i]))
    if (info.modified) parts.push(String(info.modified))
    return parts.join("  ·  ")
  }

  Process {
    id: probe
    running: false
    stdout: StdioCollector { id: probeOut; waitForEnd: true }
    stderr: StdioCollector { id: probeErr; waitForEnd: true }
    onExited: function(exitCode) {
      // A superseded probe was killed on purpose; its output is stale.
      if (root.pendingPath !== "") {
        var next = root.pendingPath
        root.pendingPath = ""
        root.startProbe(next)
        return
      }
      root.loading = false
      var raw = String(probeOut.text || "").trim()
      if (exitCode !== 0 || raw === "") {
        var err = String(probeErr.text || "").trim()
        root.info = {
          kind: "missing",
          name: root.requestedPath.split("/").pop(),
          error: err !== "" ? err : "Could not preview this file."
        }
        return
      }
      // The helper caps its own output, but this is the boundary where
      // untrusted data enters the long-lived shell, so the ceiling is enforced
      // on this side too rather than trusted from the other.
      if (raw.length > root.maxPayloadBytes) {
        root.info = {
          kind: "missing",
          name: root.requestedPath.split("/").pop(),
          error: "Preview output was too large to display safely."
        }
        return
      }
      try {
        root.info = JSON.parse(raw)
      } catch (e) {
        root.info = { kind: "missing", name: root.requestedPath.split("/").pop(),
                      error: "Preview helper returned unreadable output." }
      }
    }
  }

  IpcHandler {
    target: "andreconde.quick-look"

    function show(path: string): string {
      root.openFile(path)
      return "ok"
    }

    function dismiss(): string {
      root.close()
      return "ok"
    }

    function showOrToggle(path: string): string {
      root.showOrDismiss(path)
      return "ok"
    }

    function isOpen(): string {
      return root.opened ? "true" : "false"
    }
  }

  PanelWindow {
    id: window
    visible: root.opened
    anchors { top: true; left: true; right: true; bottom: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "andreconde-quick-look"
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.5)

      // Click anywhere outside the card to dismiss.
      MouseArea { anchors.fill: parent; onClicked: root.close() }

      FocusScope {
        id: keys
        anchors.fill: parent
        focus: root.opened

        // Space and Escape both dismiss, matching the muscle memory of the
        // key that opened the preview in the first place.
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape || event.key === Qt.Key_Space || event.key === Qt.Key_Q) {
            root.close()
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.openExternally()
            event.accepted = true
          }
        }

        Rectangle {
          id: card
          width: Math.min(parent.width * 0.78, Style.space(1040))
          height: Math.min(parent.height * 0.82, Style.space(800))
          anchors.centerIn: parent
          radius: Style.cornerRadius
          color: Color.popups.background
          border.width: Math.max(1, Style.normalBorderWidth)
          border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.28)

          // Swallow clicks so they don't reach the dismiss layer behind.
          MouseArea { anchors.fill: parent }

          Column {
            anchors.fill: parent
            anchors.margins: Style.space(16)
            spacing: Style.space(10)

            // ------------------------------------------------------- header

            Item {
              width: parent.width
              height: headerText.implicitHeight

              Row {
                id: headerText
                anchors.left: parent.left
                anchors.right: closeButton.left
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(10)

                Text {
                  text: root.kindGlyph
                  color: Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.heading
                  anchors.verticalCenter: parent.verticalCenter
                }

                Column {
                  width: parent.width - Style.space(40)
                  spacing: Style.space(2)

                  Text {
                    width: parent.width
                    text: root.displayName
                    textFormat: Text.PlainText
                    color: Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.heading
                    font.bold: true
                    elide: Text.ElideMiddle
                  }

                  Text {
                    width: parent.width
                    text: root.loading ? "Reading…" : root.metaLine()
                    textFormat: Text.PlainText
                    color: Qt.darker(Color.foreground, 1.5)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }
              }

              PanelActionButton {
                id: closeButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰅖"
                tooltipText: "Close (Esc)"
                foreground: Color.foreground
                fontFamily: Style.font.family
                onClicked: root.close()
              }
            }

            PanelSeparator {
              width: parent.width
              foreground: Color.foreground
            }

            // ------------------------------------------------------ content

            Item {
              id: body
              width: parent.width
              height: parent.height - parent.spacing * 3
                - headerText.implicitHeight - Style.space(1) - footer.implicitHeight

              // Single image: fill the pane, never upscale past 1:1 so small
              // icons don't turn into blurry posters.
              Image {
                visible: root.kind === "image" && root.previewImages.length > 0
                anchors.fill: parent
                source: root.previewImages.length > 0 ? root.fileUrl(root.previewImages[0]) : ""
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                cache: false
                mipmap: true
                sourceSize.width: root.maxDecodeEdge
                sourceSize.height: root.maxDecodeEdge
              }

              // PDF pages, rendered ahead of time by the probe.
              Flickable {
                visible: root.kind === "pdf" && root.previewImages.length > 0
                anchors.fill: parent
                contentWidth: width
                contentHeight: pages.implicitHeight
                clip: true

                Column {
                  id: pages
                  width: parent.width
                  spacing: Style.space(10)

                  Repeater {
                    model: root.kind === "pdf" ? root.previewImages : []

                    Image {
                      required property var modelData
                      width: parent.width
                      source: root.fileUrl(modelData)
                      fillMode: Image.PreserveAspectFit
                      asynchronous: true
                      cache: false
                      sourceSize.width: root.maxDecodeEdge
                      sourceSize.height: root.maxDecodeEdge
                    }
                  }
                }
              }

              // Video / audio: still frame or cover art with a play affordance.
              Item {
                visible: (root.kind === "video" || root.kind === "audio")
                anchors.fill: parent

                Image {
                  id: mediaArt
                  visible: root.previewImages.length > 0
                  anchors.fill: parent
                  source: root.previewImages.length > 0 ? root.fileUrl(root.previewImages[0]) : ""
                  fillMode: Image.PreserveAspectFit
                  asynchronous: true
                  cache: false
                  sourceSize.width: root.maxDecodeEdge
                  sourceSize.height: root.maxDecodeEdge
                }

                Text {
                  visible: !mediaArt.visible
                  anchors.centerIn: parent
                  text: root.kindGlyph
                  color: Qt.darker(Color.foreground, 1.4)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.displayLarge * 3
                }

                // Only overlay the play badge on real artwork; without art the
                // kind glyph above already fills the pane.
                Text {
                  visible: mediaArt.visible
                  anchors.centerIn: parent
                  text: "󰐊"
                  color: Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.displayLarge * 2
                  opacity: 0.85
                }

                MouseArea {
                  anchors.fill: parent
                  onClicked: root.openExternally()
                }
              }

              // Text, code, and markdown.
              Flickable {
                visible: root.kind === "text" || root.kind === "markdown"
                anchors.fill: parent
                contentWidth: width
                contentHeight: textContent.implicitHeight
                clip: true

                Text {
                  id: textContent
                  width: parent.width
                  text: String(root.info.text || "")
                  // Always literal. A preview renders files this shell did not
                  // author, and Qt's rich-text formats resolve image and HTML
                  // resource references themselves — from inside a process that
                  // never restarts. Plain text cannot reference an external
                  // resource at all, which makes that safe by construction
                  // instead of by pattern-matching the markup. Do not switch
                  // this to MarkdownText or StyledText.
                  textFormat: Text.PlainText
                  color: Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.Wrap
                  // Kept as a backstop: PlainText emits no links today, but if a
                  // richer format is ever reintroduced this keeps xdg-open from
                  // being handed file:// or a registered custom scheme.
                  onLinkActivated: function(link) {
                    if (!root.isSafeLink(link)) return
                    Quickshell.execDetached(["sh", "-lc", "xdg-open " + root.shellQuote(link) + " >/dev/null 2>&1 &"])
                  }
                }
              }

              // Directory and archive listings.
              Flickable {
                visible: root.kind === "directory" || root.kind === "archive"
                anchors.fill: parent
                contentWidth: width
                contentHeight: listing.implicitHeight
                clip: true

                Column {
                  id: listing
                  width: parent.width
                  spacing: Style.space(2)

                  Repeater {
                    model: (root.kind === "directory" || root.kind === "archive") ? root.previewEntries : []

                    Row {
                      required property var modelData
                      width: parent.width
                      spacing: Style.space(8)

                      Text {
                        text: modelData.directory ? "󰉋" : "󰈔"
                        color: Qt.darker(Color.foreground, 1.3)
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                      }

                      Text {
                        width: parent.width - Style.space(28)
                        text: String(modelData.name || "")
                        textFormat: Text.PlainText
                        color: Color.foreground
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                        elide: Text.ElideMiddle
                      }
                    }
                  }
                }
              }

              // Nothing renderable: explain rather than showing a blank card.
              Column {
                // Also covers a preview the helper refused to produce (an image
                // past the decode ceiling), so the card explains itself instead
                // of rendering an empty pane.
                visible: root.kind === "binary" || root.kind === "missing"
                  || (root.kind === "pdf" && root.previewImages.length === 0)
                  || ((root.kind === "image" || root.kind === "video" || root.kind === "audio")
                      && root.previewImages.length === 0
                      && String(root.info.error || "") !== "")
                anchors.centerIn: parent
                width: parent.width * 0.8
                spacing: Style.space(12)

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: root.kindGlyph
                  color: Qt.darker(Color.foreground, 1.4)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.displayLarge * 2
                }

                Text {
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  text: String(root.info.error || root.info.text || "No preview available for this file type.")
                  textFormat: Text.PlainText
                  color: Qt.darker(Color.foreground, 1.3)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.Wrap
                }
              }

              Text {
                visible: root.loading
                anchors.centerIn: parent
                text: "Reading…"
                color: Qt.darker(Color.foreground, 1.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }
            }

            // ------------------------------------------------------- footer

            Item {
              id: footer
              width: parent.width
              height: Math.max(pathText.implicitHeight, openButton.implicitHeight)

              Text {
                id: pathText
                anchors.left: parent.left
                anchors.right: openButton.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: root.requestedPath
                textFormat: Text.PlainText
                color: Qt.darker(Color.foreground, 1.6)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideMiddle
              }

              Button {
                id: openButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: root.requestedPath !== "" && root.kind !== "missing"
                text: "󰏌  Open"
                bordered: true
                foreground: Color.foreground
                fontFamily: Style.font.family
                fontSize: Style.font.caption
                tooltipText: "Open in the default application (Enter)"
                onClicked: root.openExternally()
              }
            }
          }
        }
      }
    }
  }
}
