require "test_helper"

class BudgetTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
  end

  test "budget_date_valid? allows going back 2 years even without entries" do
    two_years_ago = 2.years.ago.beginning_of_month
    assert Budget.budget_date_valid?(two_years_ago, family: @family)
  end

  test "budget_date_valid? allows going back to earliest entry date if more than 2 years ago" do
    # Create an entry 3 years ago
    old_account = Account.create!(
      family: @family,
      accountable: Depository.new,
      name: "Old Account",
      status: "active",
      currency: "USD",
      balance: 1000
    )

    old_entry = Entry.create!(
      account: old_account,
      entryable: Transaction.new(category: categories(:income)),
      date: 3.years.ago,
      name: "Old Transaction",
      amount: 100,
      currency: "USD"
    )

    # Should allow going back to the old entry date
    assert Budget.budget_date_valid?(3.years.ago.beginning_of_month, family: @family)
  end

  test "budget_date_valid? does not allow dates before earliest entry or 2 years ago" do
    # Create an entry 1 year ago
    account = Account.create!(
      family: @family,
      accountable: Depository.new,
      name: "Test Account",
      status: "active",
      currency: "USD",
      balance: 500
    )

    Entry.create!(
      account: account,
      entryable: Transaction.new(category: categories(:income)),
      date: 1.year.ago,
      name: "Recent Transaction",
      amount: 100,
      currency: "USD"
    )

    # Should not allow going back more than 2 years
    refute Budget.budget_date_valid?(3.years.ago.beginning_of_month, family: @family)
  end

  test "budget_date_valid? allows future dates" do
    assert Budget.budget_date_valid?(2.months.from_now, family: @family)
    assert Budget.budget_date_valid?(6.months.from_now, family: @family)
    assert Budget.budget_date_valid?(1.year.from_now, family: @family)
  end

  test "previous_budget_param returns nil when date is too old" do
    # Create a budget at the oldest allowed date
    two_years_ago = 2.years.ago.beginning_of_month
    budget = Budget.create!(
      family: @family,
      start_date: two_years_ago,
      end_date: two_years_ago.end_of_month,
      currency: "USD"
    )

    assert_nil budget.previous_budget_param
  end

  test "previous_budget_param returns param when date is valid" do
    budget = Budget.create!(
      family: @family,
      start_date: Date.current.beginning_of_month,
      end_date: Date.current.end_of_month,
      currency: "USD"
    )

    assert_not_nil budget.previous_budget_param
  end

  test "next_budget_param returns param for future months" do
    budget = Budget.create!(
      family: @family,
      start_date: Date.current.beginning_of_month,
      end_date: Date.current.end_of_month,
      currency: "USD"
    )

    assert_not_nil budget.next_budget_param
  end

  test "clone_from copies budget values and category allocations" do
    # Create source budget with values
    source_budget = Budget.create!(
      family: @family,
      start_date: Date.current.beginning_of_month,
      end_date: Date.current.end_of_month,
      currency: "USD",
      budgeted_spending: 5000,
      expected_income: 8000
    )

    # Add category allocations to source budget
    category = categories(:food)
    source_budget.budget_categories.create!(
      category: category,
      budgeted_spending: 500,
      currency: "USD"
    )

    # Create target budget
    target_budget = Budget.create!(
      family: @family,
      start_date: 1.month.from_now.beginning_of_month,
      end_date: 1.month.from_now.end_of_month,
      currency: "USD"
    )

    # Clone budget
    assert target_budget.clone_from(source_budget)

    # Verify budget values were copied
    target_budget.reload
    assert_equal 5000, target_budget.budgeted_spending
    assert_equal 8000, target_budget.expected_income

    # Verify category allocations were copied
    target_bc = target_budget.budget_categories.find_by(category: category)
    assert_not_nil target_bc
    assert_equal 500, target_bc.budgeted_spending
  end

  test "clone_from returns false for different family" do
    other_family = families(:dylan_family)
    
    source_budget = Budget.create!(
      family: other_family,
      start_date: Date.current.beginning_of_month,
      end_date: Date.current.end_of_month,
      currency: "USD",
      budgeted_spending: 5000
    )

    target_budget = Budget.create!(
      family: @family,
      start_date: 1.month.from_now.beginning_of_month,
      end_date: 1.month.from_now.end_of_month,
      currency: "USD"
    )

    refute target_budget.clone_from(source_budget)
  end
end
