class ForecastAccountSet < ApplicationRecord
  belongs_to :family

  attribute :account_ids, default: -> { [] }

  scope :alphabetically, -> { order(:name) }

  validates :name, presence: true, uniqueness: { scope: :family_id }
  validate :account_ids_present
  validate :accounts_belong_to_family

  def accounts
    family.accounts.manual.visible.where(id: account_ids)
  end

  private
    def account_ids_present
      errors.add(:account_ids, "must include at least one account") if account_ids.blank?
    end

    def accounts_belong_to_family
      return if family.blank? || account_ids.blank?

      valid_ids = family.accounts.manual.where(id: account_ids).pluck(:id)
      invalid_ids = account_ids.map(&:to_s) - valid_ids.map(&:to_s)

      errors.add(:account_ids, "must belong to the same family") if invalid_ids.any?
    end
end
