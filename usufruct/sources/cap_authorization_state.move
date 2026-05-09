// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

// CapAuthorizationState and its projectors have been absorbed into
// asset_context_state — Move requires enum pattern-matching to occur
// in the defining module, so the enum must co-reside with the match sites.
module usufruct::cap_authorization_state;
