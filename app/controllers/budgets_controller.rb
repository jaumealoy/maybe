class BudgetsController < ApplicationController
  before_action :set_budget, only: %i[show edit update clone]

  def index
    redirect_to_current_month_budget
  end

  def show
    # Get all initialized budgets for cloning (excluding current budget)
    @available_budgets = Current.family.budgets
                                       .where.not(id: @budget.id)
                                       .where.not(budgeted_spending: nil)
                                       .order(start_date: :desc)
  end

  def edit
    render layout: "wizard"
  end

  def update
    @budget.update!(budget_params)
    redirect_to budget_budget_categories_path(@budget)
  end

  def clone
    source_month_year = params[:source_month_year]
    source_start_date = Budget.param_to_date(source_month_year)
    source_budget = Current.family.budgets.find_by(start_date: source_start_date)

    if source_budget && @budget.clone_from(source_budget)
      redirect_to budget_path(@budget), notice: "Budget cloned successfully from #{source_budget.name}"
    else
      redirect_to budget_path(@budget), alert: "Failed to clone budget"
    end
  end

  def picker
    render partial: "budgets/picker", locals: {
      family: Current.family,
      year: params[:year].to_i || Date.current.year
    }
  end

  private

    def budget_create_params
      params.require(:budget).permit(:start_date)
    end

    def budget_params
      params.require(:budget).permit(:budgeted_spending, :expected_income)
    end

    def set_budget
      start_date = Budget.param_to_date(params[:month_year])
      @budget = Budget.find_or_bootstrap(Current.family, start_date: start_date)
      raise ActiveRecord::RecordNotFound unless @budget
    end

    def redirect_to_current_month_budget
      current_budget = Budget.find_or_bootstrap(Current.family, start_date: Date.current)
      redirect_to budget_path(current_budget)
    end
end
