final class DonationView: UIView {

  private enum Constants {
    static let contentInsets = UIEdgeInsets(top: 12, left: 16, bottom: -16, right: -16)
    static let actionButtonSpacing = CGFloat(10)
    static let actionButtonHeight = CGFloat(40)
    static let actionButtonMaxWidth = CGFloat(450)
  }

  enum State {
    case donate
    case crowdfunding
  }

  private let descriptionLabel = UILabel()
  private let actionButton = UIButton()
  private let backgroundImageView = UIImageView()
  private let backgroundImageShadowView = UIView()
  private var gradientLayer = CAGradientLayer()
  private var descriptionTopConstraint: NSLayoutConstraint?
  private var actionButtonBottomConstraint: NSLayoutConstraint?
  private var descriptionLeadingConstraint: NSLayoutConstraint?
  private var descriptionTrailingConstraint: NSLayoutConstraint?

  private(set) var state: State = .donate

  private var donateButtonDidTapHandler: (() -> Void)?

  init(_ state: State, action: (() -> Void)?) {
    super.init(frame: .zero)
    setupViews()
    layoutViews()
    setState(state, action: action)
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupViews()
    layoutViews()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    gradientLayer.frame = backgroundImageView.bounds
  }

  private func setupViews() {
    gradientLayer.colors = [UIColor.linkBlue().cgColor, UIColor.primary().cgColor]
    gradientLayer.startPoint = CGPoint(x: 0, y: 0)
    gradientLayer.endPoint = CGPoint(x: 0.8, y: 0.8)
    gradientLayer.frame = backgroundImageView.bounds

    backgroundImageView.contentMode = .scaleAspectFill
    backgroundImageView.layer.insertSublayer(gradientLayer, at: 0)
    backgroundImageView.layer.setCornerRadius(.buttonDefaultBig)
    backgroundImageView.clipsToBounds = true

    backgroundImageShadowView.backgroundColor = UIColor.black
    backgroundImageShadowView.layer.cornerRadius = backgroundImageView.layer.cornerRadius
    backgroundImageShadowView.layer.shadowColor = UIColor.black.cgColor
    backgroundImageShadowView.layer.shadowRadius = 6
    backgroundImageShadowView.layer.shadowOpacity = 0.3
    backgroundImageShadowView.layer.shadowOffset = .zero

    descriptionLabel.setFontStyle(.regular14, color: .blackPrimary)
    descriptionLabel.textAlignment = .center
    descriptionLabel.lineBreakMode = .byWordWrapping
    descriptionLabel.numberOfLines = 0

    actionButton.addTarget(self, action: #selector(didTapDonateButton), for: .touchUpInside)
    actionButton.titleLabel?.allowsDefaultTighteningForTruncation = true
    actionButton.titleLabel?.adjustsFontSizeToFitWidth = true
    actionButton.titleLabel?.minimumScaleFactor = 0.5

    #if DEBUG
    let longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(didLongPressDescription))
    longPressGesture.minimumPressDuration = 1.0
    descriptionLabel.addGestureRecognizer(longPressGesture)
    descriptionLabel.isUserInteractionEnabled = true
    #endif
  }

  private func layoutViews() {
    addSubview(backgroundImageView)
    addSubview(descriptionLabel)
    addSubview(actionButton)
    insertSubview(backgroundImageShadowView, belowSubview: backgroundImageView)

    backgroundImageView.translatesAutoresizingMaskIntoConstraints = false
    backgroundImageShadowView.translatesAutoresizingMaskIntoConstraints = false
    descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
    actionButton.translatesAutoresizingMaskIntoConstraints = false

    descriptionLeadingConstraint = descriptionLabel.leadingAnchor.constraint(equalTo: leadingAnchor)
    descriptionTrailingConstraint = descriptionLabel.trailingAnchor.constraint(equalTo: trailingAnchor)
    descriptionTopConstraint = descriptionLabel.topAnchor.constraint(equalTo: topAnchor)
    actionButtonBottomConstraint = actionButton.bottomAnchor.constraint(equalTo: bottomAnchor)

    NSLayoutConstraint.activate([
      backgroundImageView.leadingAnchor.constraint(equalTo: leadingAnchor),
      backgroundImageView.trailingAnchor.constraint(equalTo: trailingAnchor),
      backgroundImageView.topAnchor.constraint(equalTo: topAnchor),
      backgroundImageView.bottomAnchor.constraint(equalTo: bottomAnchor),
      backgroundImageShadowView.leadingAnchor.constraint(equalTo: backgroundImageView.leadingAnchor),
      backgroundImageShadowView.trailingAnchor.constraint(equalTo: backgroundImageView.trailingAnchor),
      backgroundImageShadowView.topAnchor.constraint(equalTo: backgroundImageView.topAnchor),
      backgroundImageShadowView.bottomAnchor.constraint(equalTo: backgroundImageView.bottomAnchor),

      descriptionTopConstraint!,
      descriptionLeadingConstraint!,
      descriptionTrailingConstraint!,

      actionButton.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: Constants.actionButtonSpacing),
      actionButton.widthAnchor.constraint(equalTo: descriptionLabel.widthAnchor).withPriority(.defaultHigh),
      actionButton.widthAnchor.constraint(lessThanOrEqualToConstant: Constants.actionButtonMaxWidth).withPriority(.defaultHigh),
      actionButton.centerXAnchor.constraint(equalTo: centerXAnchor),
      actionButton.heightAnchor.constraint(equalToConstant: Constants.actionButtonHeight),
      actionButtonBottomConstraint!,
    ])
  }

  @objc
  private func didTapDonateButton() {
    donateButtonDidTapHandler?()
  }

  @objc
  private func didLongPressDescription() {
    #if DEBUG
    Settings.resetCrowdfunding()
    Toast.show(withText: "Crowdfunding was reset.", alignment: .top)
    #endif
  }

  private func setState(_ state: State, action: (() -> Void)?) {
    switch state {
    case .donate:
      backgroundImageView.isHidden = true
      backgroundImageShadowView.isHidden = true
      descriptionLabel.text = L("donate_description")
      descriptionLabel.setFontStyleAndApply(.regular14, color: .blackPrimary)
      actionButton.setStyle(.flatNormalButtonBig)
      actionButton.setTitle(L("donate").localizedUppercase, for: .normal)

      descriptionTopConstraint?.constant = .zero
      actionButtonBottomConstraint?.constant = .zero
      descriptionLeadingConstraint?.constant = .zero
      descriptionTrailingConstraint?.constant = .zero
    case .crowdfunding:
      backgroundImageView.isHidden = false
      backgroundImageShadowView.isHidden = false
      descriptionLabel.setFontStyleAndApply(.semibold16, color: .whitePrimary)
      // TODO: pass correct text
      descriptionLabel.text = "Help keep OrganicMaps FREE & Ad-free. Support out community-driven development!"
      actionButton.setStyle(.flatYellowButtonBig)
      actionButton.setTitle(L("contribute_to_crowdfund").localizedUppercase, for: .normal)

      descriptionTopConstraint?.constant = Constants.contentInsets.top
      actionButtonBottomConstraint?.constant = Constants.contentInsets.bottom
      descriptionLeadingConstraint?.constant = Constants.contentInsets.left
      descriptionTrailingConstraint?.constant = Constants.contentInsets.right
    }

    donateButtonDidTapHandler = action
  }
}
