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

/**
 * Handles client registration errors related to the lack of e-mail and password credentials.
 */

class AuthenticationNoCredentialsErrorHandler: AuthenticationEventHandler {

    weak var statusProvider: AuthenticationStatusProvider?

    func handleEvent(currentStep: AuthenticationFlowStep, context: (NSError, UUID)) -> [AuthenticationCoordinatorAction]? {
        let (error, _) = context

        // Only handle needsToRegisterEmailToRegisterClient errors
        guard error.userSessionErrorCode == .needsToRegisterEmailToRegisterClient else {
            return nil
        }

        // If we are already registering the credentials, do not handle the error
        switch currentStep {
        case .addEmailAndPassword, .registerEmailCredentials:
            return nil
        default:
            break
        }

        // Get the credentials to start the deletion

        guard
            let user = statusProvider?.selfUser,
            let profile = statusProvider?.selfUserProfile
        else {
            return nil
        }

        let nextStep = AuthenticationFlowStep.addEmailAndPassword(user: user, profile: profile, canSkip: false)
        return [.hideLoadingView, .startPostLoginFlow, .transition(nextStep, resetStack: true)]
    }

}
