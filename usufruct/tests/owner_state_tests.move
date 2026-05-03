// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::owner_state_tests;

use std::unit_test::assert_eq;
use sui::balance::{Self, Balance};
use usufruct::owner_state;

// ─── Fixtures ──────────────────────────────────────────────────────────────────

public struct TEST_COIN has drop {}

const AMOUNT_A: u64 = 1_000;
const AMOUNT_B: u64 = 2_500;
const AMOUNT_C: u64 = 500;

fun balance_of(amount: u64): Balance<TEST_COIN> {
    balance::create_for_testing<TEST_COIN>(amount)
}

// ─── §1. Constructor ───────────────────────────────────────────────────────────

#[test]
fun new_returns_stop_flow_zero_balance() {
    let s = owner_state::new<TEST_COIN>();
    assert!(owner_state::is_stop_flow(&s));
    assert_eq!(owner_state::value(&s), 0);
    owner_state::destroy_for_testing(s);
}

// ─── §2. Transitions — happy paths ─────────────────────────────────────────────

#[test]
fun cash_flow_promotes_from_stop_flow() {
    let s = owner_state::new<TEST_COIN>();
    let s = owner_state::cash_flow(s);
    assert!(owner_state::is_cash_flow(&s));
    assert_eq!(owner_state::value(&s), 0);  // balance preserved across transition
    owner_state::destroy_for_testing(s);
}

#[test]
fun stop_flow_demotes_from_cash_flow() {
    let s = owner_state::cash_flow(owner_state::new<TEST_COIN>());
    let s = owner_state::stop_flow(s);
    assert!(owner_state::is_stop_flow(&s));
    owner_state::destroy_for_testing(s);
}

// ─── §3. Transitions — abort paths ─────────────────────────────────────────────

#[test]
#[expected_failure(abort_code = owner_state::EInvariantViolation, location = usufruct::owner_state)]
fun cash_flow_aborts_when_already_cash_flow() {
    let s = owner_state::cash_flow(owner_state::new<TEST_COIN>());
    let s = owner_state::cash_flow(s);
    owner_state::destroy_for_testing(s);
}

#[test]
#[expected_failure(abort_code = owner_state::EInvariantViolation, location = usufruct::owner_state)]
fun stop_flow_aborts_when_already_stop_flow() {
    let s = owner_state::new<TEST_COIN>();
    let s = owner_state::stop_flow(s);
    owner_state::destroy_for_testing(s);
}

// ─── §4. deposit ───────────────────────────────────────────────────────────────

#[test]
fun deposit_in_cash_flow_increases_value() {
    let s = owner_state::cash_flow(owner_state::new<TEST_COIN>());
    let s = owner_state::deposit(s, balance_of(AMOUNT_A));

    assert_eq!(owner_state::value(&s), AMOUNT_A);
    assert!(owner_state::is_cash_flow(&s));  // variant preserved
    owner_state::destroy_for_testing(s);
}

#[test]
fun deposit_chained_accumulates() {
    let s = owner_state::cash_flow(owner_state::new<TEST_COIN>());
    let s = owner_state::deposit(s, balance_of(AMOUNT_A));
    let s = owner_state::deposit(s, balance_of(AMOUNT_B));
    let s = owner_state::deposit(s, balance_of(AMOUNT_C));

    assert_eq!(owner_state::value(&s), AMOUNT_A + AMOUNT_B + AMOUNT_C);
    owner_state::destroy_for_testing(s);
}

#[test]
#[expected_failure(abort_code = owner_state::EInvariantViolation, location = usufruct::owner_state)]
fun deposit_aborts_in_stop_flow() {
    let s = owner_state::new<TEST_COIN>();
    let s = owner_state::deposit(s, balance_of(AMOUNT_A));
    owner_state::destroy_for_testing(s);
}

// ─── §5. withdraw ──────────────────────────────────────────────────────────────

#[test]
fun withdraw_drains_all_in_cash_flow() {
    let s = owner_state::cash_flow(owner_state::new<TEST_COIN>());
    let s = owner_state::deposit(s, balance_of(AMOUNT_A));
    let (s, drained) = owner_state::withdraw(s);

    assert_eq!(balance::value(&drained), AMOUNT_A);
    assert_eq!(owner_state::value(&s), 0);
    assert!(owner_state::is_cash_flow(&s));  // variant preserved across withdraw

    balance::destroy_for_testing(drained);
    owner_state::destroy_for_testing(s);
}

#[test]
fun withdraw_drains_all_in_stop_flow() {
    // Build up a non-zero balance, then transition back to StopFlow,
    // then withdraw — confirms withdraw works equivalently in both states.
    let s = owner_state::cash_flow(owner_state::new<TEST_COIN>());
    let s = owner_state::deposit(s, balance_of(AMOUNT_A));
    let s = owner_state::stop_flow(s);
    let (s, drained) = owner_state::withdraw(s);

    assert_eq!(balance::value(&drained), AMOUNT_A);
    assert_eq!(owner_state::value(&s), 0);
    assert!(owner_state::is_stop_flow(&s));

    balance::destroy_for_testing(drained);
    owner_state::destroy_for_testing(s);
}

#[test]
fun withdraw_on_zero_returns_zero_balance() {
    let s = owner_state::new<TEST_COIN>();
    let (s, drained) = owner_state::withdraw(s);

    assert_eq!(balance::value(&drained), 0);
    assert_eq!(owner_state::value(&s), 0);
    assert!(owner_state::is_stop_flow(&s));

    balance::destroy_for_testing(drained);
    owner_state::destroy_for_testing(s);
}

// ─── §6. value() — read-only ──────────────────────────────────────────────────

#[test]
fun value_reads_without_consuming() {
    let s = owner_state::cash_flow(owner_state::new<TEST_COIN>());
    let s = owner_state::deposit(s, balance_of(AMOUNT_A));

    // Multiple reads — borrow does not consume
    let _ = owner_state::value(&s);
    let _ = owner_state::value(&s);
    assert_eq!(owner_state::value(&s), AMOUNT_A);

    owner_state::destroy_for_testing(s);
}

// ─── §7. Lifecycle composition ────────────────────────────────────────────────

#[test]
fun balance_survives_transitions() {
    // Confirms the inner Balance is preserved as the variant flips.
    let s = owner_state::cash_flow(owner_state::new<TEST_COIN>());
    let s = owner_state::deposit(s, balance_of(AMOUNT_A));

    let s = owner_state::stop_flow(s);
    assert_eq!(owner_state::value(&s), AMOUNT_A);  // intact

    let s = owner_state::cash_flow(s);
    assert_eq!(owner_state::value(&s), AMOUNT_A);  // still intact

    owner_state::destroy_for_testing(s);
}

#[test]
fun full_cycle_deposit_withdraw_redeposit() {
    // Simulates two rental cycles: each opens cash flow, accumulates,
    // closes cash flow, owner withdraws, then a new cycle begins.
    let s = owner_state::cash_flow(owner_state::new<TEST_COIN>());
    let s = owner_state::deposit(s, balance_of(AMOUNT_A));
    let s = owner_state::stop_flow(s);

    let (s, first_payout) = owner_state::withdraw(s);
    assert_eq!(balance::value(&first_payout), AMOUNT_A);
    balance::destroy_for_testing(first_payout);

    let s = owner_state::cash_flow(s);
    let s = owner_state::deposit(s, balance_of(AMOUNT_B));
    let s = owner_state::deposit(s, balance_of(AMOUNT_C));
    let s = owner_state::stop_flow(s);

    let (s, second_payout) = owner_state::withdraw(s);
    assert_eq!(balance::value(&second_payout), AMOUNT_B + AMOUNT_C);
    balance::destroy_for_testing(second_payout);

    owner_state::destroy_for_testing(s);
}
