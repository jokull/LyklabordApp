//
//  EmojiPopView.swift
//  ISEmojiView
//
//  Created by Beniamin Sarkisyan on 01/08/2018.
//

import Foundation
import UIKit

internal protocol EmojiPopViewDelegate: AnyObject {
    
    /// called when the popView needs to dismiss itself
    func emojiPopViewShouldDismiss(emojiPopView: EmojiPopView)
    
}

internal class EmojiPopView: UIView {
    
    // MARK: - Internal variables
    
    /// the delegate for callback
    internal weak var delegate: EmojiPopViewDelegate?
    
    internal var currentEmoji: String = ""
    internal var emojiArray: [String] = []
    
    // MARK: - Private variables
    
    private var emojiButtons: [UIButton] = []
    private var emojisView: UIScrollView = UIScrollView()
    
    private var emojisX: CGFloat = 0.0
    private var emojisWidth: CGFloat = 0.0
    private var anchorX: CGFloat = TopPartSize.width / 2
    
    // MARK: - Init functions
    
    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: EmojiPopViewSize.width, height: EmojiPopViewSize.height))
    }
    
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }
    
    // MARK: - Override functions
    
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let result = point.x >= emojisX && point.x <= emojisX + emojisWidth && point.y >= 0 && point.y <= TopPartSize.height
        
        if !result {
            dismiss()
        }
        
        return result
    }
    
    // MARK: - Internal functions
    
    internal func move(location: CGPoint, animation: Bool = true) {
        let desiredWidth = max(TopPartSize.width, 16 + EmojiSize.width * CGFloat(emojiArray.count))
        let availableWidth = max(TopPartSize.width, UIScreen.main.bounds.width - 16)
        emojisWidth = min(desiredWidth, availableWidth)
        let frameX = min(max(8, location.x), UIScreen.main.bounds.width - emojisWidth - 8)
        anchorX = min(
            max(BottomPartSize.width / 2, location.x - frameX + TopPartSize.width / 2),
            emojisWidth - BottomPartSize.width / 2
        )
        setupUI()
        
        UIView.animate(withDuration: animation ? 0.08 : 0, animations: {
            self.alpha = 1
            self.frame = CGRect(
                x: frameX,
                y: location.y,
                width: self.emojisWidth,
                height: EmojiPopViewSize.height
            )
        }, completion: { complate in
            self.isHidden = false
        })
    }
    
    internal func dismiss() {
        UIView.animate(withDuration: 0.08, animations: {
            self.alpha = 0
        }, completion: { complate in
            self.isHidden = true
        })
    }
    
    internal func setEmoji(_ emoji: Emoji) {
        self.currentEmoji = emoji.emoji
        self.emojiArray = emoji.emojis
    }
    
}

// MARK: - Private functions

extension EmojiPopView {
    
    private func createEmojiButton(_ emoji: String) -> UIButton {
        let button = UIButton(type: .custom)
        button.titleLabel?.font = EmojiFont
        button.setTitle(emoji, for: .normal)
        button.frame = CGRect(x: CGFloat(emojiButtons.count) * EmojiSize.width, y: 0, width: EmojiSize.width, height: EmojiSize.height)
        button.addTarget(self, action: #selector(selectEmojiType(_:)), for: .touchUpInside)
        button.isUserInteractionEnabled = true
        button.accessibilityLabel = emoji
        return button
    }
    
    @objc private func selectEmojiType(_ sender: UIButton) {
        if let selectedEmoji = sender.titleLabel?.text {
            currentEmoji = selectedEmoji
            delegate?.emojiPopViewShouldDismiss(emojiPopView: self)
        }
    }
    
    private func setupUI() {
        isHidden = true
        
        self.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        
        emojisX = 0
        
        // path
        let path = maskPath()
        
        // border
        let borderLayer = CAShapeLayer()
        borderLayer.path = path
        borderLayer.strokeColor = UIColor(white: 0.8, alpha: 1).cgColor
        borderLayer.fillColor = UIColor.white.cgColor
        borderLayer.lineWidth = 1
        layer.addSublayer(borderLayer)
        
        // mask
        let maskLayer = CAShapeLayer()
        maskLayer.path = path
        
        // content layer
        let contentLayer = CALayer()
        contentLayer.frame = bounds
        contentLayer.backgroundColor = UIColor.white.cgColor
        contentLayer.mask = maskLayer
        layer.addSublayer(contentLayer)
        
        emojisView.removeFromSuperview()
        emojisView = UIScrollView(frame: CGRect(
            x: 8,
            y: 10,
            width: max(0, emojisWidth - 16),
            height: EmojiSize.height
        ))
        emojisView.showsHorizontalScrollIndicator = emojiArray.count > 6
        emojisView.alwaysBounceHorizontal = emojiArray.count > 6
        emojisView.contentSize = CGSize(
            width: CGFloat(emojiArray.count) * EmojiSize.width,
            height: EmojiSize.height
        )
        emojisView.clipsToBounds = true
        
        // add buttons
        emojiButtons = []
        for emoji in emojiArray {
            let button = createEmojiButton(emoji)
            emojiButtons.append(button)
            emojisView.addSubview(button)
        }
        
        addSubview(emojisView)
    }
    
    func maskPath() -> CGMutablePath {
        let path = CGMutablePath()
        
        path.addRoundedRect(
                 in: CGRect(
                     x: 0,
                     y: 0.0,
                     width: emojisWidth,
                     height: TopPartSize.height
                 ),
                 cornerWidth: 10,
                 cornerHeight: 10
             )

        path.addRoundedRect(
            in: CGRect(
                x: anchorX - BottomPartSize.width / 2.0,
                y: TopPartSize.height - 10,
                width: BottomPartSize.width,
                height: BottomPartSize.height + 10
            ),
            cornerWidth: 5,
            cornerHeight: 5
        )
        
        return path
    }
}
