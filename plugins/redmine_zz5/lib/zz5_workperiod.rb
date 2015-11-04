# Container for workdays
class Zz5Workperiod

  # getter and setter
  attr_accessor :workdays, :absence_types , :time_errors

  # getter
  attr_reader   :user, :user_preference, :week_days, :first_day, :last_day, :hours

  # constructor ( used by controller )
  def initialize(user, from, to = 0)
    Rails.logger.info "initialize Zz5Workperiod for from date #{from} to date #{to}"

    @user = user
    @user_preference = Zz5UserPreference.find_or_create_by_user_id(@user.id)
    @first_day = from.to_date
    if to == 0
      @last_day = from.to_date
    else
      @last_day = to.to_date
    end

    Rails.logger.info "Zz5WorkPeriod, initialize @last_day: " + @last_day.to_s


    # fill possible gaps in the past
    fill_possible_gaps(@first_day)

    @workdays = get_or_create_workdays_for_dates(@user, @first_day, @last_day)
    @absence_types = get_absence_types
    @time_errors = initialize_my(@user)

    calculate_carries

    set_employments_for_days
    set_absence_carry
  end

  def initialize_my(user_id)
    time_errors = {}
    @workdays.each do |work_day|
      spent_on = work_day.date
      Rails.logger.info "Datum: " + spent_on.to_s
      #Rails.logger.info "User : : " + user_id.to_s

      hours_on_date = TimeEntry.where(:user_id => user_id, :spent_on => spent_on).sum(:hours)
      Rails.logger.info "initialize_my, hours_on_date: " + hours_on_date.round(2).to_s
      #wd = Zz5Workday.find_by_sql(["SELECT SUM(TIME_TO_SEC(TIMEDIFF(TIMEDIFF(COALESCE(end, TIME('00:00:00')),  COALESCE(begin, TIME('00:00:00'))), COALESCE(break, TIME('00:00:00'))))) AS sum  FROM zz5_workdays WHERE user_id = ? AND date = ?;", user_id, spent_on]).first.sum

      if work_day.begin.nil?
        begin_seconds = 0
      else
        begin_seconds = Zz5GeneralUtil.timeToSeconds(work_day.begin.strftime("%H:%M"))
      end

      if work_day.end.nil?
        end_seconds = 0
      else
        end_seconds = Zz5GeneralUtil.timeToSeconds(work_day.end.strftime("%H:%M"))
      end

      if work_day.break.nil?
        break_seconds = 0
      else
        break_seconds = Zz5GeneralUtil.timeToSeconds(work_day.break.strftime("%H:%M"))
      end

      wd = end_seconds - begin_seconds - break_seconds
      Rails.logger.info "initialize_my, wd: " + (wd.to_f / 3600).round(2).to_s
      wd = (wd.to_f / 3600).round(2)
      hours_missing = 0
      if hours_on_date.round(2) != wd
        hours_missing = wd.to_f - hours_on_date.to_f
      end

      Rails.logger.info "initialize_my, hours_missing: " + hours_missing.to_s
      # account for ticket times which were not entered via the zz5 view
      # if hours_missing is negative we have a surplus of ticket times for this day
      # thus we want to increase the end time accordingly
      if !work_day.begin.nil? && hours_missing < 0
        # need conversion from seconds to hours
        normalize = Time.parse("Jan 2000")

        if work_day.end.nil?
          work_day.end = "00:00"
        end

        Rails.logger.info "work_day.end.strftime.to_f: " + work_day.end.strftime("%H:%M").to_f.to_s
        Rails.logger.info "normalize: " + normalize.to_s
        Rails.logger.info "normalize2: " + (Zz5GeneralUtil.timeToSeconds(work_day.end.strftime("%H:%M")).to_f - (hours_missing * 3600)).to_s
        Rails.logger.info "normalize3: " + (Zz5GeneralUtil.secondsToTime(Zz5GeneralUtil.timeToSeconds(work_day.end.strftime("%H:%M")).to_f - (hours_missing * 3600))).to_s

        work_end_seconds = Zz5GeneralUtil.timeToSeconds(work_day.end.strftime("%H:%M")).to_f - (hours_missing * 3600)

        if work_end_seconds > 86340
          work_end_seconds = 86340
        end

        work_day.end = Time.parse(Zz5GeneralUtil.secondsToTime(work_end_seconds), normalize)
        work_day.save
        hours_missing = 0
      end

      hours_missing = 3600 * hours_missing

      time_errors[spent_on] = hours_missing
    end
    return time_errors
  end

  def get_parent_projects
    #return Project.visible.order('lft').where(parent_id: nil)

    projects = []
    Project.visible.order('lft').each do |project|

      # add only "root" nodes
      if projects.empty? || !project.is_descendant_of?(projects.last)
        Rails.logger.info "append root project: " + project.to_s
        projects << project
      end
    end

    return projects

  end

  def calculate_carries
    #days = @workdays.keys
    @workdays.each_with_index do |work_day, index|
      if work_day != @workdays.last
        calculate_carry_for_day(work_day, @workdays[index+1])
      else
        calculate_carry_for_day(work_day)
      end
    end
  end

  # calculates vacation time since the last manual vacation carry in db
  def calculate_vacation(past, until_date)

    first_employment = Zz5Employment.where("user_id = ?", @user.id).order(:start).first

    Rails.logger.info "calculate_vacation, first_employment.start: " + first_employment.start.to_s
    Rails.logger.info "calculate_vacation, until_date: " + until_date.to_s

    if first_employment.nil?
      return result = 0
    end

    last_employment = Zz5Employment.where("user_id = ? AND start <= ?", @user.id, until_date).order(:start).last
    if last_employment.nil?
      last_employment = first_employment
    end
    Rails.logger.info "calculate_vacation, last_employment.start: " + last_employment.start.to_s

    calc_year = first_employment.start.year
    latest_date = Date.new(until_date.year, first_employment.start.month, first_employment.start.day)
    employment = first_employment.employment

    if first_employment.start != last_employment.start
      Rails.logger.info "calculate_vacation, there's more than one employment"
      calc_year = last_employment.start.year
      latest_date = Date.new(until_date.year, last_employment.start.month, last_employment.start.day)
      employment = last_employment.employment
    end

    years = until_date.year - calc_year
    Rails.logger.info "calculate_vacation, current_date.year: " + until_date.year.to_s
    Rails.logger.info "calculate_vacation, calc_year: " + calc_year.to_s
    Rails.logger.info "calculate_vacation, years: " + years.to_s
    Rails.logger.info "calculate_vacation, employment: " + employment.to_s


    effective_date = Date.new(until_date.year, first_employment.start.month, first_employment.start.day)

    if effective_date > until_date && years != 0
      years = years - 1
      Rails.logger.info "calculate_vacation, effective_date > until_date: " + years.to_s
    end

    if until_date >= effective_date && effective_date > latest_date
      years = years + 1
      Rails.logger.info "calculate_vacation, until_date >= effective_date && effective_date > latest_date: " + years.to_s
    end

    if until_date < effective_date && latest_date < effective_date && until_date.year-1 >= last_employment.start.year
      years = years + 1
      Rails.logger.info "calculate_vacation, until_date < effective_date && latest_date < effective_date && until_date.year-1 >= last_employment.start.year: " + years.to_s
    end

    Rails.logger.info "calculate_vacation, years to compute for: " + years.to_s

    result = (employment*5) * years

    return result
  end

  def get_missing_hour(date)
    return @time_errors[date]
  end

  #save zz5 work week
  def save_work_period
    Rails.logger.info "saveWorkWeek started"

    @workdays.each do |work_day|
      work_day.save
    end

    Rails.logger.info "saveWorkWeek finished"
    return true
  end

  # sets the workday data for the given wday
  def set_workday_data(day, time_begin, time_end, time_break)
    Rails.logger.info "set_workday_data started"
    Rails.logger.info "set_workday_data for " + day.date.to_s

    day.begin = time_begin
    day.end = time_end
    day.break = time_break
  end

  # returns the carry for the previous week or for a previous employment on the left-hand side
  def get_carry
    sunday = Zz5Workday.where("user_id = ? AND date = ?", @user.id, @first_day-1).first

    if sunday.nil?
      employment = Zz5Employment.where("user_id = ? AND start >= ? ", @user.id, @first_day).order(:start).first
      Rails.logger.info "workweek, get_carry, first_day: " + @first_day.to_s
      Rails.logger.info "workweek, get_carry, employment: " + employment.to_s
      carry = employment.time_carry
      return Zz5GeneralUtil.secondsToTime(carry)
    end

    carry = sunday.carry_over

    return Zz5GeneralUtil.secondsToTime(carry)
  end

  # returns the carry for the previous week or for a new employment starting this week on the right-hand side
  def get_new_carry
    employment = Zz5Employment.where("user_id = ? AND start < ? ", @user.id, @last_day).order(:start).last
    if employment.start >= @first_day && employment.start < @last_day
      carry = employment.time_carry
    else
      sunday = Zz5Workday.where("user_id = ? AND date = ?", @user.id, @first_day-1).first

      if sunday.nil?
        return "00:00"
      end

      carry = sunday.carry_over
      
    end
    return Zz5GeneralUtil.secondsToTime(carry)
  end

  # returns the carry for a single day
  def get_carry_for_a_day
    employment = Zz5Employment.where("user_id = ? AND start < ? ", @user.id.to_s, @last_day).order(:start).last
    if employment.start == @workdays[0].date
      Rails.logger.info "carry for day XX in if " + employment.time_carry.to_s
      carry = employment.time_carry
    else
      carry = @workdays[0].carry_forward
      Rails.logger.info "carry for day XX in else" + employment.time_carry.to_s
    end

    return Zz5GeneralUtil.secondsToTime(carry)
  end

  # returns the vacation carry until the specified date @until_date
  def get_vacation_entitlement(until_date=nil)

    if(until_date.nil?)
      Rails.logger.info "get_vacation_entitlement: " + @vacation_entitlement.to_s
      return Zz5GeneralUtil.secondsToTime(@vacation_entitlement)
    end

    employment = Zz5Employment.where("user_id = ? AND start < ?", @user.id.to_s, until_date.to_s).order(:start).last
    #employment = Zz5Employment.where("user_id = ? and start > ? and start <= ?", @user.id, @first_day, @@last_day).order("start ASC").first

    if employment.nil?
      return 0.0
    end
    daily_target = (employment.employment / 5)

    #consumed_vacation = Zz5Workday.find_by_sql(["SELECT SUM(TIME_TO_SEC(COALESCE(duration, TIME('00:00:00')))) AS value FROM zz5_workdays INNER JOIN zz5_absences ON zz5_workdays.id = zz5_absences.zz5_workday_id WHERE zz5_absences.zz5_absence_type_id=? AND user_id=? AND (date >= ? AND date < ? );", 4, @user.id, employment.start, until_date]).first
    absences = Zz5Absence.joins(:zz5_workday).where("zz5_absence_type_id = ? AND user_id = ? AND (zz5_workdays.date >= ? AND zz5_workdays.date < ? )", 4, @user.id, employment.start, until_date)
    consumed_vacation = 0
    absences.each do |absence|
      consumed_vacation += Zz5GeneralUtil.timeToSeconds(absence.duration.strftime "%H:%M")
    end

    vacation_entitlement = employment.vacation_entitlement.to_i - consumed_vacation.to_i
    Rails.logger.info "get_vacation_entitlement_in_days, employment.vacation_entitlement: " + employment.vacation_entitlement.to_s
    Rails.logger.info "get_vacation_entitlement_in_days, consumed_vacation: " + consumed_vacation.to_s

    added_vacation = calculate_vacation(true, until_date)
    Rails.logger.info "get_vacation_entitlement_in_days, added_vacation: " + added_vacation.to_s

    vacation_entitlement += added_vacation
    Rails.logger.info "get_vacation_entitlement_in_days, vacation_entitlement: " + vacation_entitlement.to_s

    @vacation_entitlement = vacation_entitlement

    return Zz5GeneralUtil.secondsToTime(@vacation_entitlement)
  end

  # returns the employment up to the current week
  def get_employment
    employment = Zz5Employment.where("user_id = ? AND start <= ? ", @user.id.to_s, @first_day.to_s).order(:start).last

    if employment.nil?
      Rails.logger.info "get_employment, employment is nil"
      return 0.0
    end

    Rails.logger.info "get_employment, employment start: " + employment.start.to_s
    Rails.logger.info "get_employment, employment: " + employment.employment.to_s



    return employment.employment
  end

  # returns the vacation carry of the previous week in days
  def get_vacation_entitlement_in_days(until_date)
    
    # nillable param!!!!
    #if until date == nil then until_date = first_day


    employment = Zz5Employment.where("user_id = ? AND start <= ?", @user.id.to_s, until_date.to_s).order(:start).last
    #employment = Zz5Employment.where("user_id = ? and start > ? and start <= ?", @user.id, @first_day, @@last_day).order("start ASC").first

    if employment.nil?
      return 0.0
    end
    daily_target = (employment.employment / 5)
    #consumed_vacation = Zz5Workday.find_by_sql(["SELECT SUM(TIME_TO_SEC(COALESCE(duration, TIME('00:00:00')))) AS value FROM zz5_workdays INNER JOIN zz5_absences ON zz5_workdays.id = zz5_absences.zz5_workday_id WHERE zz5_absences.zz5_absence_type_id=? AND user_id=? AND (date >= ? AND date < ? );", 4, @user.id, employment.start, until_date]).first
    absences = Zz5Absence.joins(:zz5_workday).where("zz5_absence_type_id = ? AND user_id = ? AND (zz5_workdays.date >= ? AND zz5_workdays.date < ? )", 4, @user.id, employment.start, until_date)
    consumed_vacation = 0
    absences.each do |absence|
      consumed_vacation += Zz5GeneralUtil.timeToSeconds(absence.duration.strftime "%H:%M")
    end

    vacation_entitlement = employment.vacation_entitlement.to_i - consumed_vacation.to_i
    Rails.logger.info "get_vacation_entitlement_in_days, employment.vacation_entitlement: " + employment.vacation_entitlement.to_s
    Rails.logger.info "get_vacation_entitlement_in_days, consumed_vacation: " + consumed_vacation.to_s

    added_vacation = calculate_vacation(true, until_date)
    Rails.logger.info "get_vacation_entitlement_in_days, added_vacation: " + added_vacation.to_s

    vacation_entitlement += added_vacation
    Rails.logger.info "get_vacation_entitlement_in_days, vacation_entitlement: " + vacation_entitlement.to_s
    Rails.logger.info "get_vacation_entitlement_in_days, daily_target: " + daily_target.to_s

    return ((vacation_entitlement/daily_target).round(2))
  end

  # returns the special leave carry of the previous week
  def get_special_leave_carry
    return Zz5GeneralUtil.secondsToTime(@special_leave)
  end

  # returns the care_leave carry of the previous week
  def get_care_leave_carry
    return Zz5GeneralUtil.secondsToTime(@care_leave)
  end

  # returns the sick_leave carry of the previous week
  def get_sick_leave_carry
    return Zz5GeneralUtil.secondsToTime(@sick_leave)
  end

  # returns the name of Austrian holiday of the given date
  def get_holiday_name(this_date)

    if this_date == nil
      return ""
    end

    if this_date.holidays(:at)[0] != nil
      return this_date.holidays(:at)[0][:name]
    end

    is_user_holiday = Zz5SpecialHoliday.find_by_user_id_and_holiday_date(User.current.id,this_date)
    is_all_user_holiday = Zz5SpecialHoliday.find_by_user_id_and_holiday_date(-1,this_date)
    recurring_date = Date.new(1900, this_date.month, this_date.day)
    is_all_user_holiday_recurring = Zz5SpecialHoliday.where(:user_id => -1, :holiday_date => recurring_date).first

    if is_user_holiday != nil
      return is_user_holiday.holiday_name
    elsif is_all_user_holiday != nil
      return is_all_user_holiday.holiday_name
    elsif is_all_user_holiday_recurring != nil
      return is_all_user_holiday_recurring.holiday_name
    else
      return ""

    end

  end


  # Determine if the given date is a holiday in Austria.
  #
  # the method returns 0 if the it is a holiday and > 0 if it is a working day
  # the returned factor can be multiplied with the daily working time
  def is_holiday(this_date)
    return Zz5GeneralUtil.is_holiday(this_date)
  end

  # now works an on a per day basis allowing the calculation of carries for
  # arbitrary amounts of time. @next_day needs to be supplied if it is in the
  # @workdays hashmap to allow for proper updating of days in the data structure (current time period)
  def calculate_carry_for_day(day, next_day = 0)

    # get old_carry_forward of first day of next week
    # calculate carries for current week
    # calculate update_carry by subtracting new_carry_forward from old_carry_forward
    # update carry_forward of all subsequent existing workdays with date > first_workday_of_next_week
    # update carry_over of all subsequent existing workdays with date >= first_workday_of_next_week
    # (for query look at Absence model)

    if day.nil?
      return
    end

    next_day_date = day.date + 1.days
    if next_day == 0
      next_day = Zz5Workday.where(:user_id => @user.id).where(:date => next_day_date).first_or_create
      set_employment_for_day(next_day)
    end
    old_carry_forward = next_day.carry_forward
    Rails.logger.info "calculate_carries, old_carry_forward: " + old_carry_forward.to_s

    employment = Zz5Employment.where("user_id = ? AND start <= ?", @user.id, day.date).order(:start).last
    if employment.nil?
      employment = Zz5Employment.where(:user_id => @user.id).order(:start).last
    end

    Rails.logger.info "employment in calculate carries:  " + day.date.to_s + employment.start.to_s
    Rails.logger.info "---------------------------------------"

    # -------------------------------------------
    # day is a holiday or a regular workday
    # -------------------------------------------
    # look into initialize method for possible problems

    if is_holiday(day.date) == 0
      calculate_carry_for_holiday(day, next_day, employment)
    else
      calculate_carry_for_workday(day, next_day, employment)
    end

    new_carry_forward = next_day.carry_forward
    Rails.logger.info "calculate_carries, new_carry_forward: " + new_carry_forward.to_s

    update_carry = new_carry_forward - old_carry_forward
    Rails.logger.info "calculate_carries, update_carry: " + update_carry.to_s

    next_employment = Zz5Employment.where("user_id = ? AND start >= ?", @user.id, next_day_date).order(:start).limit(1).first
    until_date = Zz5Workday.where("user_id = ? AND date >= ?", @user.id, next_day_date).last

    if !until_date.nil?
     until_date = until_date.date
    else
     until_date = 0
    end

    unless next_employment.nil?
     until_date = next_employment.start - 1
    end
    Zz5Workday.update_all(['carry_forward = carry_forward + ?', update_carry], ['user_id = ? AND date >= ? AND date <= ?', @user.id, next_day_date+1.days, until_date])
    Zz5Workday.update_all(['carry_over = carry_over + ?', update_carry], ['user_id = ? AND date >= ? AND date <= ?', @user.id, next_day_date, until_date])
  end

  private

  def calculate_carry_for_workday(day, next_day, employment)

    worked = get_time_worked_in_seconds(day)

    if day.date == employment.start
      # -----------------------------------------
      # work day is first day of employment
      # set carry_forward from employment's time carry
      # -----------------------------------------
      Rails.logger.info "calculate_carries, " + day.date.to_s + " is the first day of an employment"
      day.carry_forward = employment.time_carry
      Rails.logger.info "calculate_carries, carry_forward: " + day.carry_forward.to_s
      # check if hours have been logged for this work day
      target = Zz5GeneralUtil.timeToSeconds(Time.at(day.target).strftime "%H:%M")

      Rails.logger.info "calculate_carries, worked: " + worked.to_s
      Rails.logger.info "calculate_carries, target: " + target.to_s
      Rails.logger.info "calculate_carries, absences: " + day.absences.to_s
      diff = worked - target + day.absences

      day.carry_over = day.carry_forward + diff
      Rails.logger.info "calculate_carries, carry_over: " + day.carry_over.to_s
      day.save
      # write carry_over to carry_forward of following day
      next_day.carry_forward = day.carry_over
      next_day.save

    elsif day.date > employment.start
      # -----------------------------------------
      # work day is a regular day
      # -----------------------------------------
      Rails.logger.info "calculate_carries, " + day.date.to_s + " is a regular working day"
      Rails.logger.info "calculate_carries, worked: " + worked.to_s
      Rails.logger.info "calculate_carries, target: " + Zz5GeneralUtil.timeToSeconds(Time.at(day.target).strftime "%H:%M").to_s
      Rails.logger.info "calculate_carries, absences: " + day.absences.to_s

      diff = worked - Zz5GeneralUtil.timeToSeconds(Time.at(day.target).strftime "%H:%M") + day.absences

      # set overtime allowance accordingly
      day.carry_forward = consider_overtime_allowance(day, employment)
      Rails.logger.info "calculate_carries, carry_forward: " + day.carry_forward.to_s

      #Zz5Workday.update_all(["carry_over = carry_forward + ?", diff], ["id = ?", day.id])

      day.carry_over = day.carry_forward + diff
      day.save
      Rails.logger.info "calculate_carries, carry_over: " + day.carry_over.to_s

      next_day.carry_forward = day.carry_over
      next_day.save
    end
  end

  def calculate_carry_for_holiday(day, next_day, employment)
    Rails.logger.info "calculate_carries_for_holiday, " + day.date.to_s + " is a holiday/weekend"

    # check if hours have been logged for this work day
    worked = get_time_worked_in_seconds(day)

    if day.date == employment.start
      Rails.logger.info "calculate_carries_for_holiday, " + day.date.to_s + " is the first day of an employment"

      day.carry_forward = employment.time_carry
      Rails.logger.info "calculate_carries_for_holiday, carry_forward: " + day.carry_forward.to_s

      target = Zz5GeneralUtil.timeToSeconds(Time.at(day.target).strftime "%H:%M")

      Rails.logger.info "calculate_carries_for_holiday, worked: " + worked.to_s
      Rails.logger.info "calculate_carries_for_holiday, target: " + target.to_s
      Rails.logger.info "calculate_carries_for_holiday, absences: " + day.absences.to_s
      diff = worked - target + day.absences

      day.carry_over = day.carry_forward + diff
      Rails.logger.info "calculate_carries_for_holiday, carry_over: " + day.carry_over.to_s
      day.save

      # write carry_over to carry_forward of following day
      next_day.carry_forward = day.carry_over
      next_day.save
    else
      Rails.logger.info "calculate_carries_for_holiday, working on a weekend: " + worked.to_s
      # set overtime allowance accordingly
      day.carry_forward = consider_overtime_allowance(day, employment)
      day.carry_over = day.carry_forward + worked
      day.carry_over = 0 if day.date.sunday? && employment.is_all_in == true
      day.save

      # write carry_over to carry_forward of following day
      # next_work_day = Zz5Workday.where("user_id = ? AND date = ?", @user.id, day.date+1).first
      next_day.carry_forward = day.carry_over
      next_day.save
    end
  end

  def get_time_worked_in_seconds (day)
    if day.begin.nil?
      return 0
    end

    if day.break.nil?
      day.break = "00:00"
    end

    if day.end.nil?
      day.end = "00:00"
    end

    Rails.logger.info "get_time_worked_in_seconds, end: " + Time.at(day.end).to_s
    Rails.logger.info "get_time_worked_in_seconds, begin: " + Time.at(day.begin).to_s

    worked = day.end - day.begin
    Rails.logger.info "get_time_worked_in_seconds,k worked: " + worked.to_s
    break_seconds = Zz5GeneralUtil.timeToSeconds(Time.at(day.break).strftime "%H:%M")
    return worked - break_seconds
  end

  def consider_overtime_allowance(day, employment)
    if employment.overtime_allowance && day.date == day.date.at_beginning_of_month && day.carry_forward > 0
      Rails.logger.info "calculate_carries, overtime allowance is considered"

      # get previous workday to check whether or not ot allowance applies
      prev_day = Zz5Workday.where(:user_id => @user.id).where(:date => day.date-1.days).first

      Rails.logger.info "calculate_carries, prev day " + prev_day.date.to_s + " carry_over: " + prev_day.carry_over.to_s

      if employment.overtime_allowance > prev_day.carry_over
        carry_forward = 0
      else
        overtime_hours = calculate_monthly_overtime(prev_day.date)
        if employment.overtime_allowance < overtime_hours
          overtime_hours = employment.overtime_allowance
        end
        carry_forward = prev_day.carry_over - overtime_hours
      end

      return carry_forward
    end

    return day.carry_forward
  end

  def calculate_monthly_overtime(day)
    # get target time of month by summing all workdays with date >= beginning_of_month AND date <= end_of_month
    # get the worked hours of month by subtracting carry_over of last day from carry_forward of first day
    beginning_of_month = day.beginning_of_month
    Rails.logger.info "calculate_monthly_overtime, beginning_of_month: " + beginning_of_month.to_s
    end_of_month = day

    first_day = Zz5Workday.where(:user_id => @user.id, :date => beginning_of_month).first

    if first_day.nil?
      first_day = Zz5Workday.where(:user_id => @user.id).order(:date).first
    end

    last_day = Zz5Workday.where(:user_id => @user.id, :date => end_of_month).first

    worked_time = last_day.carry_over - first_day.carry_forward
    # calculate worked - target to get the difference for the month

    if worked_time < 0
      return 0
    end

    #overtime = worked_time - target_time
    Rails.logger.info "calculate_monthly_overtime, worked_time: " + worked_time.to_s
    #Rails.logger.info "calculate_monthly_overtime, target_time: " + target_time.to_s
    #Rails.logger.info "calculate_monthly_overtime, overtime_hours: " + overtime.to_s
    return worked_time
  end

  def set_absence_carry

    @vacation_entitlement = 0

    employment_data = Zz5Employment.find_by_sql(["select id, start, vacation_entitlement from zz5_employments where user_id = ? and start <= ? order by start desc;", @user.id, @first_day]).first
    new_employment_data = Zz5Employment.find_by_sql(["select id, start, vacation_entitlement from zz5_employments where user_id = ? and start > ? and start <= ? order by start asc;", @user.id, @first_day, @last_day]).first

    if employment_data.nil?
      employment_data = Zz5Employment.find_by_sql(["select id, start, vacation_entitlement from zz5_employments where user_id = ? and start >= ? order by start asc;", @user.id, @first_day]).first
      Rails.logger.info "HI! My name is employment with start: " + employment_data.start.to_s

      if employment_data.nil?
        Rails.logger.error "No employment data found for user with ID = " + @user.id.to_s
        return
      end
    end

    Rails.logger.info "first_day: " + @first_day.to_s
    Rails.logger.info "@last_day: " + @last_day.to_s

    #consumed_vacation = Zz5Workday.find_by_sql(["SELECT SUM(TIME_TO_SEC(COALESCE(duration, TIME('00:00:00')))) AS value FROM zz5_workdays INNER JOIN zz5_absences ON zz5_workdays.id = zz5_absences.zz5_workday_id WHERE zz5_absences.zz5_absence_type_id=? AND user_id=? AND (date >= ? AND date < ? );", 4, @user.id, employment_data.start, @first_day]).first
    absences = Zz5Absence.joins(:zz5_workday).where("zz5_absence_type_id = ? AND user_id = ? AND (zz5_workdays.date >= ? AND zz5_workdays.date < ? )", 4, @user.id, employment_data.start, @first_day)
    consumed_vacation = 0
    absences.each do |absence|
      consumed_vacation += Zz5GeneralUtil.timeToSeconds(absence.duration.strftime "%H:%M")
    end

    added_vacation = calculate_vacation(false, @first_day)
    Rails.logger.info "consumed_vacation: " + consumed_vacation.to_s
    Rails.logger.info "added_vacation: " + added_vacation.to_s
    Rails.logger.info "employment_data.vacation_entitlement: " + employment_data.vacation_entitlement.to_s
    @vacation_entitlement = employment_data.vacation_entitlement.to_i - consumed_vacation.to_i

    if !new_employment_data.nil?
      @vacation_entitlement = new_employment_data.vacation_entitlement.to_i - consumed_vacation.to_i
      Rails.logger.info " new_employment.vacation_entitlement " + new_employment_data.vacation_entitlement.to_s
    end

    Rails.logger.info "this is your vacation entitlement: " + @vacation_entitlement.to_s
    @vacation_entitlement += added_vacation

    if @vacation_entitlement < 0
      @vacation_entitlement -= 60
    end

    Rails.logger.info "this is your vacation entitlement: " + @vacation_entitlement.to_s

  end

  # sets the employment target for a single day
  def set_employment_for_day(day)
    if is_holiday(day.date) == 0
      day.target = Time.new(2000);
    else
      employment = Zz5Employment.where("user_id = ? AND start <= ?", @user.id, day.date).order(:start).last

      if employment.nil?
        employment = Zz5Employment.where(:user_id => @user.id).order(:start).last
      end

      if day.date >= employment.start
        day.target = Time.at((employment.employment / 5) * is_holiday(day.date)).utc.strftime "%H:%M"
        Rails.logger.info "set_employment_for_day, target for " + day.date.to_s + " = " + day.target.to_s
      end
    end
    day.save
  end

  # set employment targets of each workday in a workperiod
  def set_employments_for_days
    @workdays.each do |zz5_work_day|
      if is_holiday(zz5_work_day.date) == 0
        zz5_work_day.target = Time.new(2000);
      else
        employment = Zz5Employment.where("user_id = ? AND start <= ?", @user.id, zz5_work_day.date).order(:start).last

        if employment.nil?
          employment = Zz5Employment.where(:user_id => @user.id).order(:start).last
        end

        if zz5_work_day.date >= employment.start
          zz5_work_day.target = Time.at((employment.employment / 5) * is_holiday(zz5_work_day.date)).utc.strftime "%H:%M"
          Rails.logger.info "target for " + zz5_work_day.date.to_s + " = " + zz5_work_day.target.to_s
        end
      end

      zz5_work_day.save
    end
  end


  # retrieves or creates all workdays
  # ==== Attributes
  #
  # * +user+ - The user object
  def get_or_create_workdays_for_dates(user, from, to)
    Rails.logger.info "get_or_create_workdays_for_dates with date " + from.to_s

    workdays = Array.new
    wdate = from

    while wdate <= to
      workday = Zz5Workday.where(:user_id => user.id).where(:date => wdate).first_or_create
      workdays.push(workday)
      Rails.logger.info "get_or_create_workdays_for_dates, date: " + workday.date.to_s
      wdate = wdate+1.days
    end

    return workdays
  end


  # creates missing workday records beginning with the last date found in zz5_workdays
  # returns if there's no gap to fill: last_saved_date >= until_date
  # until the specified date in @until_date
  def fill_possible_gaps(until_date)


    # ALWAYS gets the last day
    last_saved_workday = Zz5Workday.where("user_id = ?", @user.id).order(:date).last

    if last_saved_workday.nil?
      Rails.logger.info "No Workdays for this user yet!"
      last_saved_workday = Zz5Workday.where(:user_id => @user.id).where(:date => Zz5Employment.where("user_id = ?", @user.id).order(:start).first.start).first_or_create
      last_saved_workday.target = Time.at((Zz5Employment.where("user_id = ?", @user.id).order(:start).first.employment / 5) * is_holiday(last_saved_workday.date)).utc.strftime "%H:%M"
      last_saved_workday.save
    end

    last_saved_date = last_saved_workday.date
    if last_saved_date >= until_date
      Rails.logger.info "no gaps to fill"
      return
    end

    calculate_carry_for_day(last_saved_workday)

    current_date = last_saved_date + 1.days
    Rails.logger.info "fill_possible_gaps, last saved workday date: " + last_saved_date.to_s

    no_of_employments = Zz5Employment.where("user_id = ? AND start > ? AND start <= ?", @user.id, last_saved_date, until_date).order(:start).count + 1
    Rails.logger.info "fill_possible_gaps, number of employments: " + no_of_employments.to_s

    while no_of_employments != 0

      Rails.logger.info "fill_possible_gaps, current_date: " + current_date.to_s
      current_employment = Zz5Employment.where("user_id = ? AND start <= ?", @user.id, current_date).order(:start).last

      if current_employment.nil?
        break
      end

      if no_of_employments == 1
        next_until_date = until_date
      else
        next_employment = Zz5Employment.where("user_id = ? AND start > ?", @user.id, current_date).order(:start).first
        next_until_date = next_employment.start
      end

      Rails.logger.info "fill_possible_gaps, current employment start: " + current_employment.start.to_s
      Rails.logger.info "fill_possible_gaps, current employment employment: " + current_employment.employment.to_s
      Rails.logger.info "fill_possible_gaps, next until date: " + next_until_date.to_s


      while current_date < next_until_date
        workday = Zz5Workday.where(:user_id => @user.id).where(:date => current_date).first_or_create

        if is_holiday(current_date) == 0
          workday.target = Time.new(current_date.year);
        else
          workday.target = Time.at((current_employment.employment / 5) * is_holiday(current_date)).utc.strftime "%H:%M"
        end

        workday.save
        calculate_carry_for_day(workday)
        current_date = current_date + 1.days
      end

      no_of_employments = no_of_employments - 1
    end
  end

  def get_absence_types
    result = {}

    Zz5AbsenceType.all.each do |t|
      result[t.name] = t.id
    end

    return result
  end

    def self.get_week_dates(first_day_of_the_week)
    # A hash with all dates in this week
    return week_dates = {
      "monday" => first_day_of_the_week,
      "tuesday" => first_day_of_the_week + 1,
      "wednesday" => first_day_of_the_week + 2,
      "thursday" => first_day_of_the_week + 3,
      "friday" => first_day_of_the_week + 4,
      "saturday" => first_day_of_the_week + 5,
    "sunday" => first_day_of_the_week + 6}
  end

end
