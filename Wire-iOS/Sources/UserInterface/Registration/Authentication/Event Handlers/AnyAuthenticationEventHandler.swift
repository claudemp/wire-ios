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

/**
 * A box for authentication event handlers that have the same context type.
 */

class AnyAuthenticationEventHandler<Context> {

    /// The name of the handler.
    private(set) var name: String

    private let statusProviderGetter: () -> AuthenticationStatusProvider?
    private let statusProviderSetter: (AuthenticationStatusProvider?) -> Void
    private let handlerBlock: (AuthenticationFlowStep, Context) -> [AuthenticationCoordinatorAction]?

    /**
     * Creates a type-erased box for the specified event handler.
     */

    init<Handler: AuthenticationEventHandler>(_ handler: Handler) where Handler.Context == Context {
        statusProviderGetter = { handler.statusProvider }
        statusProviderSetter = { handler.statusProvider = $0 }
        self.name = String(describing: Handler.self)
        handlerBlock = handler.handleEvent
    }

    /// The current status provider.
    var statusProvider: AuthenticationStatusProvider? {
        get { return statusProviderGetter() }
        set { statusProviderSetter(newValue) }
    }

    /// Handles the event.
    func handleEvent(currentStep: AuthenticationFlowStep, context: Context) -> [AuthenticationCoordinatorAction]? {
        return handlerBlock(currentStep, context)
    }

}
