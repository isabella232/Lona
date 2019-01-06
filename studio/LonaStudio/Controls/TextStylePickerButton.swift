import Foundation
import Cocoa

final class TextStylePickerButton: NSButton, CSControl {

    var data: CSData {
        get { return CSData.String(textValue) }
        set { textValue = newValue.stringValue }
    }

    var onChangeData: (CSData) -> Void = { _ in }

    var textValue: String = CSTypography.defaultFont.id {
        didSet {
            setButtonTitle(value: textValue)
        }
    }

    var onChangeTextValue: (String) -> Void = {_ in}

    func setup() {
        action = #selector(handleClick)
        target = self

        setButtonType(.momentaryPushIn)
        imagePosition = .imageLeft
        alignment = .left
        bezelStyle = .rounded

        setButtonTitle(value: textValue)
    }

    func setButtonTitle(value: String) {
        attributedTitle = CSTypography.getFontBy(id: value).font.with(size: 14).apply(to: value)
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setup()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    func showPopover() {
        let picker = TextStylePickerView(selected: data.stringValue) {[weak self] (item) in
            guard let strongSelf = self else { return }
            strongSelf.textValue = item.id
            strongSelf.onChangeTextValue(strongSelf.textValue)
            strongSelf.onChangeData(strongSelf.data)
        }
        picker.popover.show(relativeTo: NSRect.zero, of: self, preferredEdge: .maxY)
    }

    @objc func handleClick() {
        showPopover()
    }

    private func smallSizeAttributeText(with csFont: TextStyle) -> NSAttributedString {
        return csFont.with(size: 14).apply(to: textValue)
    }
}
