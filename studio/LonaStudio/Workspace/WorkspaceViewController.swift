//
//  WorkspaceViewController.swift
//  LonaStudio
//
//  Created by Devin Abbott on 8/22/18.
//  Copyright © 2018 Devin Abbott. All rights reserved.
//

import AppKit
import FileTree
import Foundation

private func getDirectory() -> URL? {
    let dialog = NSOpenPanel()

    dialog.title                   = "Choose export directory"
    dialog.showsResizeIndicator    = true
    dialog.showsHiddenFiles        = false
    dialog.canCreateDirectories    = true
    dialog.canChooseDirectories    = true
    dialog.canChooseFiles          = false

    return dialog.runModal() == NSApplication.ModalResponse.OK ? dialog.url : nil
}

private func requestSketchFileSaveURL() -> URL? {
    let dialog = NSSavePanel()

    dialog.title                   = "Export .sketch file"
    dialog.showsResizeIndicator    = true
    dialog.showsHiddenFiles        = false
    dialog.canCreateDirectories    = true
    dialog.allowedFileTypes        = ["sketch"]

    if dialog.runModal() == NSApplication.ModalResponse.OK {
        return dialog.url
    } else {
        // User clicked on "Cancel"
        return nil
    }
}

class WorkspaceViewController: NSSplitViewController {
    private enum DocumentAction: String {
        case cancel = "Cancel"
        case discardChanges = "Discard"
        case saveChanges = "Save"
    }

    private let splitViewResorationIdentifier = "tech.lona.restorationId:workspaceViewController2"

    // MARK: Lifecycle

    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        setUpViews()
        setUpLayout()
        update()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpViews()
        setUpLayout()
        update()
    }

    // MARK: Public

    public var document: NSDocument? { didSet { update() } }

    // Called from the ComponentMenu
    public func addLayer(_ layer: CSLayer) {
        componentEditorViewController.addLayer(layer)
    }

    // MARK: Private

    private var component: CSComponent? {
        return (document as? ComponentDocument)?.component
    }

    private var inspectedContent: InspectorView.Content?

    private lazy var fileTree: FileTree = {
        return FileTree(rootPath: LonaModule.current.url.path)
    }()
    private lazy var fileTreeViewController: NSViewController = {
        return NSViewController(view: fileTree)
    }()

    private lazy var componentEditorViewController = ComponentEditorViewController()

    private lazy var colorEditorViewController: ColorEditorViewController = {
        let controller = ColorEditorViewController()

        controller.onInspectColor = { color in
            self.inspectedContent = InspectorView.Content(color)
            self.update()
        }

        controller.onChangeColors = { actionName, newColors, selectedColor in
            guard
                let document = self.document as? JSONDocument,
                let content = document.content,
                case let .colors(oldColors) = content else { return }

            let oldInspectedContent = self.inspectedContent
            let newInspectedContent = InspectorView.Content(selectedColor)

            UndoManager.shared.run(
                name: actionName,
                execute: {[unowned self] in
                    document.content = .colors(newColors)
                    self.inspectedContent = newInspectedContent
                    self.inspectorView.content = newInspectedContent
                    controller.colors = newColors
                },
                undo: {[unowned self] in
                    document.content = .colors(oldColors)
                    self.inspectedContent = oldInspectedContent
                    self.inspectorView.content = oldInspectedContent
                    controller.colors = oldColors
                }
            )
        }

        return controller
    }()

    private lazy var inspectorView = InspectorView()
    private lazy var inspectorViewController: NSViewController = {
        return NSViewController(view: inspectorView)
    }()

    // A document's window controllers are deallocated if there are no associated documents.
    // This ViewController can contain a reference.
    private var windowController: NSWindowController?

    override func viewDidAppear() {
        windowController = view.window?.windowController
    }

    override func viewDidDisappear() {
        windowController = nil
    }

    private func setUpViews() {
        splitView.dividerStyle = .thin
        splitView.autosaveName = NSSplitView.AutosaveName(rawValue: splitViewResorationIdentifier)
        splitView.identifier = NSUserInterfaceItemIdentifier(rawValue: splitViewResorationIdentifier)

        fileTree.defaultFont = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
        fileTree.displayNameForFile = { path in
            let url = URL(fileURLWithPath: path)
            return url.pathExtension == "component" ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
        }

        fileTree.imageForFile = { path, size in
            let url = URL(fileURLWithPath: path)

            func defaultImage(for path: String) -> NSImage {
                return NSWorkspace.shared.icon(forFile: path)
            }

            if url.pathExtension == "component" {
                guard let component = LonaModule.current.component(named: url.deletingPathExtension().lastPathComponent),
                    let canvas = component.computedCanvases().first,
                    let caseItem = component.computedCases(for: canvas).first
                    else { return defaultImage(for: path) }

                let config = ComponentConfiguration(
                    component: component,
                    arguments: caseItem.value.objectValue,
                    canvas: canvas
                )

                let canvasView = CanvasView(
                    canvas: canvas,
                    rootLayer: component.rootLayer,
                    config: config,
                    options: [RenderOption.assetScale(1)]
                )

                guard let data = canvasView.dataRepresentation(scaledBy: 0.25),
                    let image = NSImage(data: data)
                    else { return defaultImage(for: path) }
                image.size = NSSize(width: size.width, height: (image.size.height / image.size.width) * size.height)
                return image
            } else {
                return defaultImage(for: path)
            }
        }

        fileTree.onAction = { path in
            guard let document = self.document else {
                let url = URL(fileURLWithPath: path)

                NSDocumentController.shared.openDocument(withContentsOf: url, display: false, completionHandler: { newDocument, documentWasAlreadyOpen, error in

                    guard let newDocument = newDocument else {
                        Swift.print("Failed to open", url, error as Any)
                        return
                    }

                    if documentWasAlreadyOpen {
                        newDocument.showWindows()
                        return
                    }

                    guard let windowController = self.view.window?.windowController else { return }

                    newDocument.addWindowController(windowController)
                    windowController.document = newDocument
                    self.document = newDocument

                    // Set this after updating the document (which calls update)
                    // TODO: There shouldn't need to be an implicit ordering. Maybe we call update() manually.
                    self.inspectedContent = nil
                })

                return
            }

            if document.fileURL?.path == path { return }

            if document.isDocumentEdited {
                let name = document.fileURL?.lastPathComponent ?? "Untitled"
                guard let result = Alert(
                    items: [
                        DocumentAction.cancel,
                        DocumentAction.discardChanges,
                        DocumentAction.saveChanges],
                    messageText: "Save changes to \(name)",
                    informativeText: "The document \(name) has unsaved changes. Save them now?").run()
                    else { return }
                switch result {
                case .saveChanges:
                    var saveURL: URL

                    if let url = document.fileURL {
                        saveURL = url
                    } else {
                        let dialog = NSSavePanel()

                        dialog.title                   = "Save .component file"
                        dialog.showsResizeIndicator    = true
                        dialog.showsHiddenFiles        = false
                        dialog.canCreateDirectories    = true
                        dialog.allowedFileTypes        = ["component"]

                        // User canceled the save. Don't swap out the document.
                        if dialog.runModal() != NSApplication.ModalResponse.OK {
                            return
                        }

                        guard let url = dialog.url else { return }

                        saveURL = url
                    }

                    document.save(to: saveURL, ofType: document.fileType ?? "DocumentType", for: NSDocument.SaveOperationType.saveOperation, completionHandler: { error in
                        // TODO: We should not close the document if it fails to save
                        Swift.print("Failed to save", saveURL, error as Any)
                    })

                    LonaPlugins.current.trigger(eventType: .onSaveComponent)
                case .cancel:
                    return
                case .discardChanges:
                    break
                }
            }

            let url = URL(fileURLWithPath: path)

            NSDocumentController.shared.openDocument(withContentsOf: url, display: false, completionHandler: { newDocument, documentWasAlreadyOpen, error in

                guard let newDocument = newDocument else {
                    Swift.print("Failed to open", url, error as Any)
                    NSDocumentController.shared.removeDocument(document)
                    let windowController = document.windowControllers[0]
                    windowController.document = nil
                    document.removeWindowController(windowController)
                    self.document = nil
                    self.inspectedContent = nil

                    return
                }

                if documentWasAlreadyOpen {
                    newDocument.showWindows()
                    return
                }

                NSDocumentController.shared.removeDocument(document)

                let windowController = document.windowControllers[0]
                newDocument.addWindowController(windowController)
                windowController.document = newDocument
                self.document = newDocument

                // Set this after updating the document (which calls update)
                // TODO: There shouldn't need to be an implicit ordering. Maybe we call update() manually.
                self.inspectedContent = nil
            })
        }
    }

    private lazy var mainItem = NSSplitViewItem(viewController: componentEditorViewController)

    private func setUpLayout() {
        minimumThicknessForInlineSidebars = 180

        let contentListItem = NSSplitViewItem(contentListWithViewController: fileTreeViewController)
        addSplitViewItem(contentListItem)

        mainItem.minimumThickness = 300
        addSplitViewItem(mainItem)

        let sidebarItem = NSSplitViewItem(viewController: inspectorViewController)
        sidebarItem.canCollapse = false
        sidebarItem.minimumThickness = 280
        sidebarItem.maximumThickness = 280
        addSplitViewItem(sidebarItem)
    }

    private func update() {
        inspectorView.content = inspectedContent

        guard let document = document else {
            removeSplitViewItem(mainItem)
            mainItem.viewController = NSViewController(view: NSView())
            insertSplitViewItem(mainItem, at: 1)
            return
        }

        if document is ComponentDocument {
            if mainItem.viewController != componentEditorViewController {
                removeSplitViewItem(mainItem)
                mainItem.viewController = componentEditorViewController
                insertSplitViewItem(mainItem, at: 1)
            }

            componentEditorViewController.component = component

            componentEditorViewController.onInspectLayer = { layer in
                guard let layer = layer else {
                    self.inspectedContent = nil
                    return
                }
                self.inspectedContent = .layer(layer)
                self.inspectorView.content = .layer(layer)
            }

            componentEditorViewController.onChangeInspectedLayer = {
                self.inspectorView.content = self.inspectedContent
            }

            inspectorView.onChangeContent = { layer, changeType in
                self.componentEditorViewController.reloadLayerListWithoutModifyingSelection()
            }
        } else if let document = document as? JSONDocument {
            if let content = document.content, case .colors(let colors) = content {
                if mainItem.viewController != colorEditorViewController {
                    removeSplitViewItem(mainItem)
                    mainItem.viewController = colorEditorViewController
                    insertSplitViewItem(mainItem, at: 1)
                }

                colorEditorViewController.colors = colors
            } else {
                removeSplitViewItem(mainItem)
                mainItem.viewController = NSViewController(view: NSView())
                insertSplitViewItem(mainItem, at: 1)
                return
            }

            inspectorView.onChangeContent = { newContent, changeType in
                if UndoManager.shared.isUndoing || UndoManager.shared.isRedoing {
                    return
                }

                guard let oldContent = self.inspectedContent else { return }
                guard let colors = document.content else { return }

                switch (oldContent, newContent, colors) {
                case (.color(let oldColor), .color(let newColor), .colors(let colors)):

                    // Perform update using indexes in case the id was changed
                    guard let index = colors.index(where: { $0.id == oldColor.id }) else { return }

                    let updated = colors.enumerated().map { offset, element in
                        return index == offset ? newColor : element
                    }

                    // TODO: Improve this. It may be conflicting with the textfield's built-in undo
                    UndoManager.shared.run(
                        name: "Edit Color",
                        execute: {[unowned self] in
                            document.content = .colors(updated)
                            self.inspectedContent = .color(newColor)
                            self.inspectorView.content = .color(newColor)
                            self.colorEditorViewController.colors = updated
                        },
                        undo: {[unowned self] in
                            document.content = .colors(colors)
                            self.inspectedContent = .color(oldColor)
                            self.inspectorView.content = .color(oldColor)
                            self.colorEditorViewController.colors = colors
                        }
                    )
                default:
                    break
                }
            }
        }
    }

    // Subscriptions

    var subscriptions: [() -> Void] = []

    override func viewWillAppear() {
        subscriptions.append(LonaPlugins.current.register(eventType: .onReloadWorkspace) {
            self.component?.layers
                .filter({ $0 is CSComponentLayer })
                .forEach({ layer in
                    let layer = layer as! CSComponentLayer
                    layer.reload()
                })

            self.update()
        })
    }

    override func viewWillDisappear() {
        subscriptions.forEach({ sub in sub() })
    }

    // Key handling

    override func keyDown(with event: NSEvent) {
        let characters = event.charactersIgnoringModifiers!

        if characters == String(Character(" ")) {
            componentEditorViewController.canvasPanningEnabled = true
        }

        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        let characters = event.charactersIgnoringModifiers!

        if characters == String(Character(" ")) {
            componentEditorViewController.canvasPanningEnabled = false
        }

        super.keyUp(with: event)
    }
}

// MARK: - IBActions

extension WorkspaceViewController {
    @IBAction func zoomToActualSize(_ sender: AnyObject) {
        componentEditorViewController.zoomToActualSize()
    }

    @IBAction func zoomIn(_ sender: AnyObject) {
        componentEditorViewController.zoomIn()
    }

    @IBAction func zoomOut(_ sender: AnyObject) {
        componentEditorViewController.zoomOut()
    }

    @IBAction func exportToAnimation(_ sender: AnyObject) {
        guard let component = component, let url = getDirectory() else { return }

        RenderSurface.renderToAnimations(component: component, directory: url)
    }

    @IBAction func exportCurrentModuleToImages(_ sender: AnyObject) {
        guard let url = getDirectory() else { return }

        RenderSurface.renderCurrentModuleToImages(savedTo: url)
    }

    @IBAction func exportToImages(_ sender: AnyObject) {
        guard let component = component, let url = getDirectory() else { return }

        RenderSurface.renderToImages(component: component, directory: url)
    }

    @IBAction func exportToVideo(_ sender: AnyObject) {
        guard let component = component, let url = getDirectory() else { return }

        RenderSurface.renderToVideos(component: component, directory: url)
    }

    @IBAction func exportToSketch(_ sender: AnyObject) {
        guard let component = component, let outputFile = requestSketchFileSaveURL() else { return }

        let mainBundle = Bundle.main

        guard let pathToNode = mainBundle.path(forResource: "node", ofType: "") else { return }

        let dirname = URL(fileURLWithPath: pathToNode).deletingLastPathComponent()
        let componentToSketch = dirname
            .appendingPathComponent("Modules", isDirectory: true)
            .appendingPathComponent("component-to-sketch", isDirectory: true)

        let output = RenderSurface.renderToJSON(layout: component.canvasLayoutAxis, component: component, selected: nil)
        guard let data = output.toData() else { return }

        guard #available(OSX 10.12, *) else { return }

        DispatchQueue.global().async {
            let task = Process()

            // Set the task parameters
            task.launchPath = pathToNode
            task.arguments = [
                componentToSketch.appendingPathComponent("index.js").path,
                outputFile.path
            ]
            task.currentDirectoryPath = componentToSketch.path

            let stdin = Pipe()
            let stdout = Pipe()

            task.standardInput = stdin
            task.standardOutput = stdout

            // Launch the task
            task.launch()

            stdin.fileHandleForWriting.write(data)
            stdin.fileHandleForWriting.closeFile()

            task.waitUntilExit()

            let handle = stdout.fileHandleForReading
            let data = handle.readDataToEndOfFile()
            let out = NSString(data: data, encoding: String.Encoding.utf8.rawValue)

            Swift.print("result", out ?? "stdout empty")
        }
    }

    @IBAction func addComponent(_ sender: AnyObject) {
        guard let component = component else { return }

        let dialog = NSOpenPanel()

        dialog.title                   = "Choose a .component file"
        dialog.showsResizeIndicator    = true
        dialog.showsHiddenFiles        = false
        dialog.canChooseDirectories    = false
        dialog.canCreateDirectories    = false
        dialog.allowsMultipleSelection = false
        dialog.allowedFileTypes        = ["component"]

        if dialog.runModal() == NSApplication.ModalResponse.OK {
            if let url = dialog.url {
                let newLayer = CSComponentLayer.make(from: url)

                // Add number suffix if needed
                newLayer.name = component.getNewLayerName(startingWith: newLayer.name)

                componentEditorViewController.addLayer(newLayer)
            }
        } else {
            // User clicked on "Cancel"
            return
        }
    }

    func addChildren() {
        let newLayer = CSLayer(name: "Children", type: .children, parameters: [
            "width": 100.toData(),
            "height": 100.toData(),
            "backgroundColor": "#D8D8D8".toData()
        ])

        componentEditorViewController.addLayer(newLayer)
    }

    func addImage() {
        guard let component = component else { return }

        let name = component.getNewLayerName(startingWith: "Image")

        let newLayer = CSLayer(name: name, type: .image, parameters: [
            "width": 100.toData(),
            "height": 100.toData(),
            "backgroundColor": "#D8D8D8".toData()
        ])

        componentEditorViewController.addLayer(newLayer)
    }

    func addAnimation() {
        guard let component = component else { return }

        let name = component.getNewLayerName(startingWith: "Animation")

        let newLayer = CSLayer(name: name, type: .animation, parameters: [
            "width": 100.toData(),
            "height": 100.toData(),
            "backgroundColor": "#D8D8D8".toData()
        ])

        componentEditorViewController.addLayer(newLayer)
    }

    func addView() {
        guard let component = component else { return }

        let name = component.getNewLayerName(startingWith: "View")

        let newLayer = CSLayer(name: name, type: .view, parameters: [
            "width": 100.toData(),
            "height": 100.toData(),
            "backgroundColor": "#D8D8D8".toData()
        ])

        componentEditorViewController.addLayer(newLayer)
    }

    func addText() {
        guard let component = component else { return }

        let name = component.getNewLayerName(startingWith: "Text")

        let newLayer = CSLayer(name: name, type: .text, parameters: [
            "text": "Text goes here".toData(),
            "widthSizingRule": "Shrink".toData(),
            "heightSizingRule": "Shrink".toData()
        ])

        componentEditorViewController.addLayer(newLayer)
    }

}
