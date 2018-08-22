//
// Wire
// Copyright (C) 2018 Wire Swiss GmbH
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see http://www.gnu.org/licenses/.
//

import Foundation
import WireSyncEngine

typealias AuthenticationStepViewController = UIViewController & AuthenticationCoordinatedViewController

protocol ObservableSessionManager: SessionManagerType {
    func addSessionManagerCreatedSessionObserver(_ observer: SessionManagerCreatedSessionObserver) -> Any
}

extension SessionManager: ObservableSessionManager {}

/**
 * Manages the flow of authentication for the user. Decides which steps to take for login, registration
 * and team creation.
 */

class AuthenticationCoordinator: NSObject, AuthenticationEventHandlingManagerDelegate {

    weak var presenter: NavigationController?
    weak var delegate: AuthenticationCoordinatorDelegate?

    let log = ZMSLog(tag: "Auth")

    // MARK: - Event Handling Properties

    let eventHandlingManager = AuthenticationEventHandlingManager()

    var statusProvider: AuthenticationStatusProvider? {
        return delegate
    }

    // MARK: - State

    public fileprivate(set) var currentStep: AuthenticationFlowStep = .landingScreen
    var flowStack: [AuthenticationFlowStep] = []
    var currentViewController: AuthenticationStepViewController?

    private let companyLoginController = CompanyLoginController(withDefaultEnvironment: ())
    private let interfaceBuilder = AuthenticationInterfaceBuilder()

    private let sessionManager: ObservableSessionManager
    private let unauthenticatedSession: UnauthenticatedSession
    private let registrationStatus: RegistrationStatus
    private var loginObservers: [Any] = []
    private var postLoginObservers: [Any] = []
    private var initialSyncObserver: Any?

    // MARK: - Initialization

    init(presenter: NavigationController, unauthenticatedSession: UnauthenticatedSession, sessionManager: ObservableSessionManager) {
        self.presenter = presenter
        self.sessionManager = sessionManager
        self.unauthenticatedSession = unauthenticatedSession
        self.registrationStatus = unauthenticatedSession.registrationStatus
        super.init()

        registrationStatus.delegate = self
        companyLoginController?.delegate = self
        flowStack = [.landingScreen]

        loginObservers = [
            PreLoginAuthenticationNotification.register(self, for: unauthenticatedSession),
            PostLoginAuthenticationNotification.addObserver(self),
            sessionManager.addSessionManagerCreatedSessionObserver(self)
        ]

        presenter.delegate = self
        eventHandlingManager.configure(delegate: self)
    }

}

// MARK: - State Management

extension AuthenticationCoordinator {

    /**
     * Transitions to the next step in the stack.
     *
     * This method changes the current step, generates a new interface if needed,
     * and changes the stack (either appends the new step to the list of previous steps,
     * or resets the stack if you request it).
     *
     * - parameter step: The step to transition to.
     * - parameter resetStack: Whether transitioning to this step resets the previous stack
     * of view controllers in the navigation controller. You should pass `true` if your step
     * is at the beginning of a new "logical flow" (ex: deleting clients).
     */

    func transition(to step: AuthenticationFlowStep, resetStack: Bool = false) {
        currentStep = step

        defer {
            if resetStack {
                flowStack = [step]
            } else {
                flowStack.append(step)
            }
        }

        guard step.needsInterface else {
            return
        }

        guard let stepViewController = interfaceBuilder.makeViewController(for: step) else {
            fatalError("Step \(step) requires user interface, but the interface builder does not support it.")
        }

        stepViewController.authenticationCoordinator = self
        currentViewController = stepViewController

        let containerViewController = KeyboardAvoidingViewController(viewController: stepViewController)

        if resetStack {
            presenter?.backButtonEnabled = false
            presenter?.setViewControllers([containerViewController], animated: true)
        } else {
            presenter?.backButtonEnabled = step.allowsUnwind
            presenter?.pushViewController(containerViewController, animated: true)
        }
    }

    /**
     * Unwind the state to the previous state if possible.
     *
     * This sets the current step back to the previous state, if we recorded it.
     *
     * You should call this method:
     * - when a non-visual step fails and you need to go back to step that started it
     * - when the navigation controller pops the current view controller
     */

    func unwind(requireInterfaceStep: Bool = false) {
        guard flowStack.count >= 2 else {
            return
        }

        repeat {
            flowStack.removeLast()
            currentStep = flowStack.last!
        } while requireInterfaceStep ? !currentStep.needsInterface : false
    }

}

// MARK: - Event Handling

extension AuthenticationCoordinator: SessionManagerCreatedSessionObserver {

    func sessionManagerCreated(userSession: ZMUserSession) {
        log.info("Session manager created session: \(userSession)")
        initialSyncObserver = ZMUserSession.addInitialSyncCompletionObserver(self, userSession: userSession)
    }

    /**
     * Registers the post-login observation tokens if they were not already registered.
     */

    fileprivate func registerPostLoginObserversIfNeeded() {
        guard postLoginObservers.isEmpty else {
            log.warn("Post login observers are already registered.")
            return
        }

        guard let selfUser = delegate?.selfUser else {
            log.warn("Post login observers were not registered because there is no self user.")
            return
        }

        guard let sharedSession = delegate?.sharedUserSession else {
            log.warn("Post login observers were not registered because there is no user session.")
            return
        }

        guard let userProfile = delegate?.selfUserProfile else {
            log.warn("Post login observers were not registered because there is no user profile.")
            return
        }

        postLoginObservers = [
            userProfile.add(observer: self),
            UserChangeInfo.add(observer: self, for: selfUser, userSession: sharedSession)!
        ]
    }

    /**
     * Executes the actions in response to an event.
     */

    func executeActions(_ actions: [AuthenticationCoordinatorAction]) {
        for action in actions {
            switch action {
            case .showLoadingView:
                presenter?.showLoadingView = true

            case .hideLoadingView:
                presenter?.showLoadingView = false

            case .completeBackupStep:
                unauthenticatedSession.continueAfterBackupImportStep()

            case .executeFeedbackAction(let action):
                currentViewController?.executeErrorFeedbackAction?(action)

            case .presentAlert(let alertModel):
                presentAlert(for: alertModel)

            case .presentErrorAlert(let alertModel):
                presentErrorAlert(for: alertModel)

            case .completeLoginFlow:
                delegate?.userAuthenticationDidComplete(registered: false)

            case .completeRegistrationFlow:
                delegate?.userAuthenticationDidComplete(registered: true)

            case .startPostLoginFlow:
                registerPostLoginObserversIfNeeded()

            case .transition(let nextStep, let resetStack):
                transition(to: nextStep, resetStack: resetStack)

            case .performPhoneLoginFromRegistration(let phoneNumber):
                sendLoginCode(phoneNumber: phoneNumber, isResend: false)

            case .configureNotifications:
                sessionManager.configureUserNotifications()

            case .startIncrementalUserCreation(let unregisteredUser):
                transition(to: .incrementalUserCreation(unregisteredUser, .start))
                eventHandlingManager.handleEvent(ofType: .registrationStepSuccess)

            case .setMarketingConsent(let consentValue):
                updateUnregisteredUser {
                    $0.marketingConsent = consentValue
                }

            case .completeUserRegistration:
                finishRegisteringUser()

            case .sendPostRegistrationFields(let unregisteredUser):
                sendPostRegistrationFields(for: unregisteredUser)

            case .unwindState:
                unwind()
            }
        }
    }

    private func presentErrorAlert(for alertModel: AuthenticationCoordinatorErrorAlert) {
        presenter?.showAlert(forError: alertModel.error) { _ in
            self.executeActions(alertModel.completionActions)
        }
    }

    private func presentAlert(for alertModel: AuthenticationCoordinatorAlert) {
        let alert = UIAlertController(title: alertModel.title, message: alertModel.message, preferredStyle: .alert)

        for actionModel in alertModel.actions {
            let action = UIAlertAction(title: actionModel.title, style: .default) { _ in
                self.executeActions(actionModel.coordinatorActions)
            }

            alert.addAction(action)
        }

        presenter?.present(alert, animated: true)
    }

}

// MARK: - Actions

extension AuthenticationCoordinator {

    // MARK: - Starting the Flow

    /**
     * Call this method when the application becomes unauthenticated and that the user
     * needs to authenticate.
     *
     * - parameter error: The error that caused the unauthenticated state, if any.
     * - parameter numberOfAccounts: The number of accounts that are signed in with the app.
     */

    func startAuthentication(with error: NSError?, numberOfAccounts: Int) {
        eventHandlingManager.handleEvent(ofType: .flowStart(error, numberOfAccounts))
    }

    // MARK: - Registration Code

    /**
     * Starts the registration flow with the specified phone number.
     *
     * This step will ask the registration status to send the activation code
     * by text message. It will advance the state to `.sendActivationCode`.
     *
     * - parameter phoneNumber: The phone number to activate and register with.
     */

    @objc(startRegistrationWithPhoneNumber:)
    func startRegistration(phoneNumber: String) {
        guard case let .createCredentials(unregisteredUser) = currentStep else {
            log.error("Cannot start phone outside of registration flow.")
            return
        }

        let unverifiedCredential = UnverifiedCredential.phone(phoneNumber)
        unregisteredUser.credentials = .phone(number: phoneNumber)

        sendActivationCode(unverifiedCredential, unregisteredUser, isResend: false)
    }

    /**
     * Starts the registration flow with the specified e-mail and password.
     *
     * This step will ask the registration status to send the activation code
     * by e-mail. It will advance the state to `.sendActivationCode`.
     *
     * - parameter name: The display name of the user.
     * - parameter email: The email address to activate and register with.
     * - parameter password: The password to link with the e-mail.
     */

    @objc(startRegistrationWithName:email:password:)
    func startRegistration(name: String, email: String, password: String) {
        guard case let .createCredentials(unregisteredUser) = currentStep else {
            log.error("Cannot start email registration outside of registration flow.")
            return
        }

        let unverifiedCredential = UnverifiedCredential.email(email)
        unregisteredUser.credentials = .email(address: email, password: password)
        unregisteredUser.name = name

        sendActivationCode(unverifiedCredential, unregisteredUser, isResend: false)
    }

    /// Sends the registration activation code.
    private func sendActivationCode(_ credential: UnverifiedCredential, _ user: UnregisteredUser, isResend: Bool) {
        presenter?.showLoadingView = true
        transition(to: .sendActivationCode(credential, user: user, isResend: isResend))
        registrationStatus.sendActivationCode(to: credential)
    }

    /// Asks the registration
    private func activateCredentials(credential: UnverifiedCredential, user: UnregisteredUser, code: String) {
        presenter?.showLoadingView = true
        transition(to: .activateCredentials(credential, user: user, code: code))
        registrationStatus.checkActivationCode(credential: credential, code: code)
    }

    // MARK: - Login

    /**
     * Starts the phone number login flow for the given phone number.
     * - parameter phoneNumber: The phone number to validate for login.
     */

    @objc(startLoginWithPhoneNumber:)
    func startLogin(phoneNumber: String) {
        presenter?.showLoadingView = true
        let nextStep = AuthenticationFlowStep.sendLoginCode(phoneNumber: phoneNumber, isResend: false)
        transition(to: nextStep)
        sendLoginCode(phoneNumber: phoneNumber, isResend: false)
    }

    /**
     * Requests an e-mail login for the specified credentials.
     * - parameter credentials: The e-mail credentials to sign in with.
     */

    @objc(requestEmailLoginWithCredentials:)
    func requestEmailLogin(with credentials: ZMEmailCredentials) {
        presenter?.showLoadingView = true
        transition(to: .authenticateEmailCredentials(credentials))
        unauthenticatedSession.login(with: credentials)
    }

    /// Sends the login verification code to the phone number.
    private func sendLoginCode(phoneNumber: String, isResend: Bool) {
        presenter?.showLoadingView = true
        let nextStep = AuthenticationFlowStep.sendLoginCode(phoneNumber: phoneNumber, isResend: isResend)
        transition(to: nextStep)
        unauthenticatedSession.requestPhoneVerificationCodeForLogin(phoneNumber: phoneNumber)
    }

    /// Requests a phone login for the specified credentials.
    private func requestPhoneLogin(with credentials: ZMPhoneCredentials) {
        presenter?.showLoadingView = true
        transition(to: .authenticatePhoneCredentials(credentials))
        unauthenticatedSession.login(with: credentials)
    }

    // MARK: - Generic Verification

    /**
     * Resends the verification code to the user, if allowed by the current state.
     */

    @objc func resendVerificationCode() {
        switch currentStep {
        case .enterLoginCode(let phoneNumber):
            sendLoginCode(phoneNumber: phoneNumber, isResend: true)
        case .enterActivationCode(let credential, let user):
            sendActivationCode(credential, user, isResend: true)
        default:
            log.error("Cannot send verification code in the current state (\(currentStep)")
        }
    }

    /**
     * Checks the verification code provided by the user, and continues to the next appropriate step.
     */

    @objc(continueFlowWithVerificationCode:)
    func continueFlow(withVerificationCode code: String) {
        switch currentStep {
        case .enterLoginCode(let phoneNumber):
            let credentials = ZMPhoneCredentials(phoneNumber: phoneNumber, verificationCode: code)
            requestPhoneLogin(with: credentials)

        case .enterActivationCode(let unverifiedCredential, let user):
            activateCredentials(credential: unverifiedCredential, user: user, code: code)

        default:
            log.error("Cannot continue flow with user code in the current state (\(currentStep)")
        }
    }

    // MARK: - E-Mail Registration

    /**
     * Skips the add e-mail and password step, if possible.
     */

    @objc func skipAddEmailAndPassword() {
        // no-op
    }

    /**
     * Sets th e-mail and password credentials for the current user.
     */

    @objc func setEmailCredentialsForCurrentUser(_ credentials: ZMEmailCredentials) {
        guard case let .addEmailAndPassword(_, profile, _) = currentStep else {
            return
        }

        transition(to: AuthenticationFlowStep.registerEmailCredentials(credentials))
        presenter?.showLoadingView = true

        let result = setCredentialsWithProfile(profile, credentials: credentials) && SessionManager.shared?.update(credentials: credentials) == true

        if !result {
            let error = NSError(code: .invalidEmail, userInfo: nil)
            emailUpdateDidFail(error)
        }
    }

    @discardableResult
    private func setCredentialsWithProfile(_ profile: UserProfile, credentials: ZMEmailCredentials) -> Bool {
        do {
            try profile.requestSettingEmailAndPassword(credentials: credentials)
            return true
        } catch {
            return false
        }
    }

    // MARK: - E-Mail Verification

    /**
     * This method re-sends the e-mail verification code if possible.
     */

    @objc func resendEmailVerificationCode() {
//        guard case let .verifyEmailCredentials(credentials) = currentStep else {
//            return
//        }
//
//        guard let userProfile = delegate?.selfUserProfile else {
//            return
//        }
//
//        presenter?.showLoadingView = true
//
//        // We can assume that the validation will succeed, as it only fails when there is no
//        // email and/or password in the email credentials, which we already checked before.
//        setCredentialsWithProfile(userProfile, credentials: credentials)
    }

    // MARK: - Backup

    /**
     * Call this method to mark the backup step as completed.
     */

    @objc func completeBackupStep() {
        unauthenticatedSession.continueAfterBackupImportStep()
    }

    // MARK: UI Events

    /**
     * Manually display the company login flow.
     */

    @objc func startCompanyLoginFlowIfPossible() {
        switch currentStep {
        case .provideCredentials:
            companyLoginController?.displayLoginCodePrompt()
        default:
            return
        }
    }

    /**
     * Call this method when the corrdinated view controller appears.
     */

    @objc func currentViewControllerDidAppear() {
        switch currentStep {
        case .landingScreen, .provideCredentials:
            companyLoginController?.isAutoDetectionEnabled = true
            companyLoginController?.detectLoginCode()

        default:
            companyLoginController?.isAutoDetectionEnabled = false
        }
    }

    /**
     * Call this method when the corrdinated view controller disappears.
     */

    @objc func currentViewControllerDidDisappear() {
        companyLoginController?.isAutoDetectionEnabled = false
    }

    // MARK: Linear Registration

    /**
     * Notifies the registration state observers that the user accepted the
     * terms of service.
     */

    @objc func acceptTermsOfService() {
        updateUnregisteredUser {
            $0.acceptedTermsOfService = true
        }
    }

    /**
     * Notifies the registration state observers that the user set an account name.
     */

    @objc(setUserName:)
    func setUserName(_ userName: String) {
        updateUnregisteredUser {
            $0.name = userName
        }
    }

    /**
     * Notifies the registration state observers that the user set a profile picture.
     */

    @objc(setProfilePictureWithData:)
    func setProfilePicture(_ data: Data) {
        // unauthenticatedSession.setProfileImage(imageData: data)

        updateUnregisteredUser {
            $0.profileImageData = data
        }
    }

    private func updateUnregisteredUser(_ updateBlock: (UnregisteredUser) -> Void) {
        guard case let .incrementalUserCreation(unregisteredUser, _) = currentStep else {
            log.warn("Cannot update unregistered user outide of the incremental user creation flow")
            return
        }

        updateBlock(unregisteredUser)
        eventHandlingManager.handleEvent(ofType: .registrationStepSuccess)
    }

    private func finishRegisteringUser() {
        guard case let .incrementalUserCreation(unregisteredUser, _) = currentStep else {
            return
        }

        transition(to: .createUser(unregisteredUser))
        registrationStatus.create(user: unregisteredUser)
    }

    private func sendPostRegistrationFields(for unregisteredUser: UnregisteredUser) {
        guard let userSession = statusProvider?.sharedUserSession else {
            log.error("Could not save the marketing consent and , as there is no user session for the user.")
            return
        }

        let consentValue = unregisteredUser.marketingConsent ?? false
        UIAlertController.newsletterSubscriptionDialogWasDisplayed = true

        userSession.submitMarketingConsent(with: consentValue)
        userSession.profileUpdate.updateImage(imageData: unregisteredUser.profileImageData!)
    }

}

// MARK: - User Session Events

extension AuthenticationCoordinator: UserProfileUpdateObserver, ZMUserObserver {

    // MARK: Email Update

    func emailUpdateDidFail(_ error: Error!) {
        presenter?.showLoadingView = false

        guard case .registerEmailCredentials = currentStep else {
            return
        }

        if (error as NSError).userSessionErrorCode == .emailIsAlreadyRegistered {
            currentViewController?.executeErrorFeedbackAction?(.clearInputFields)
        }

        presenter?.showAlert(forError: error) { _ in
            self.unwind()
        }
    }

    func passwordUpdateRequestDidFail() {
        presenter?.showLoadingView = false

        guard case .registerEmailCredentials = currentStep else {
            return
        }

        presenter?.showAlert(forMessage: "error.updating_password".localized, title: nil) { _ in
            self.unwind()
        }
    }

    func didSentVerificationEmail() {
        presenter?.showLoadingView = false

//        guard case .registerEmailCredentials(let credentials) = currentStep else {
//            return
//        }
//
//        transition(to: .verifyEmailCredentials(credentials))
    }

    func userDidChange(_ changeInfo: UserChangeInfo) {
        guard changeInfo.profileInformationChanged else {
            return
        }

        switch currentStep {
        case .registerEmailCredentials:
            guard let selfUser = delegate?.selfUser else {
                return
            }

            guard selfUser.emailAddress?.isEmpty == false else {
                return
            }

            // TODO: GDPR consent
            delegate?.userAuthenticationDidComplete(registered: false)

        default:
            break
        }
    }

}

// MARK: - CompanyLoginControllerDelegate

extension AuthenticationCoordinator: CompanyLoginControllerDelegate {

    func controller(_ controller: CompanyLoginController, presentAlert alert: UIAlertController) {
        presenter?.present(alert, animated: true)
    }

    func controller(_ controller: CompanyLoginController, showLoadingView: Bool) {
        presenter?.showLoadingView = showLoadingView
    }

}