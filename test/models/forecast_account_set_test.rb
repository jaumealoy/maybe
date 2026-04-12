require "test_helper"

class ForecastAccountSetTest < ActiveSupport::TestCase
  test "requires accounts from the same family" do
    account_set = ForecastAccountSet.new(
      family: families(:dylan_family),
      name: "Mixed",
      account_ids: [ accounts(:depository).id, accounts(:other_asset).id ]
    )

    assert_predicate account_set, :valid?

    account_set.account_ids = [ accounts(:depository).id, SecureRandom.uuid ]

    assert_not account_set.valid?
    assert_includes account_set.errors[:account_ids], "must belong to the same family"
  end
end
