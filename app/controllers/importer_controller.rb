require 'csv'
require 'tempfile'

MultipleIssuesForUniqueValue = Class.new(StandardError)
NoIssueForUniqueValue = Class.new(StandardError)

Journal.class_exec do
  def empty?
    (details.empty? && notes.blank?)
  end
end

class ImporterController < ApplicationController
  unloadable

  before_filter :find_project

  ISSUE_ATTRS = [:id, :subject, :assigned_to, :fixed_version,
                 :author, :description, :category, :priority, :tracker, :status,
                 :start_date, :due_date, :done_ratio, :estimated_hours,
                 :parent_issue, :watchers, :project, :spent_time, :activity, :user_for_spent_time]

  def index; end


  def match
    # Delete existing iip to ensure there can't be two iips for a user
    ImportInProgress.delete_all(["user_id = ?",User.current.id])
    # save import-in-progress data
    iip = ImportInProgress.find_or_create_by(user_id: User.current.id)
    iip.quote_char = params[:wrapper].blank? ? '"' : params[:wrapper]
    iip.col_sep = params[:splitter].blank? ? ',' : params[:splitter]
    iip.created = Time.new
    params[:file].blank? ? iip.csv_data = "" : iip.csv_data = params[:file].read.force_encoding(params[:encoding]).encode("UTF-8")
    # check that the encoding provided by the user was correct, and pops up an error otherwise
    if !iip.csv_data.valid_encoding?
      iip.csv_data = ""
      flash[:error] = l(:error_invalid_encoding)
    end
    iip.save
    return if flash[:error].present?

    # Put the timestamp in the params to detect
    # users with two imports in progress
    @import_timestamp = iip.created.strftime("%Y-%m-%d %H:%M:%S")
    params[:file].blank? ? @original_filename = "" : @original_filename = params[:file].original_filename

    flash.delete(:error)
    validate_csv_data(iip.csv_data)
    return if flash[:error].present?

    sample_data(iip)
    return if flash[:error].present?

    set_csv_headers(iip)
    return if flash[:error].present?


    # fields
    @attrs = Array.new
    ISSUE_ATTRS.each do |attr|
      if User.current && User.current.language.present?
        @attrs << [l_or_humanize(attr, :prefix=>"field_", :default => attr, :locale =>  User.current.language), attr]
      end
    end
    @project.all_issue_custom_fields.each do |cfield|
      @attrs.push([cfield.name, cfield.name])
    end
    IssueRelation::TYPES.each_pair do |rtype, rinfo|
      @attrs.push([l_or_humanize(rinfo[:name]),rtype])
    end
    @attrs.sort!
  end


  def result
    # used for bookkeeping
    flash.delete(:error)

    init_globals
    # Used to optimize some work that has to happen inside the loop
    unique_attr_checked = false

    # Retrieve saved import data
    iip = ImportInProgress.find_by(user_id: User.current.id)
    if iip == nil
      flash[:error] = l(:error_importer_no_import_in_progress, user: User.current.firstname + " " + User.current.lastname)
      return
    end
    if iip.created.strftime("%Y-%m-%d %H:%M:%S") != params[:import_timestamp]
      flash[:error] = l(:error_importer_import_already_in_progress)
      return
    end

    # which options were turned on?
    update_issue = params[:update_issue]
    update_other_project = params[:update_other_project]
    add_categories = params[:add_categories]
    add_versions = params[:add_versions]
    use_issue_id = params[:use_issue_id].present? ? true : false
    ignore_non_exist = params[:ignore_non_exist]
    allow_closed_issues_update = params[:allow_closed_issues_update]
    # Set a thread flag for use in ActionMailer interceptor
    Thread.current[:bulk_import_disable_notifications] = params[:disable_send_emails].present? ? true : false

    # which fields should we use? what maps to what?
    unique_field = params[:unique_field].blank? ? nil : params[:unique_field]
    spent_time_field = params[:spent_time].blank? ? nil : params[:spent_time]
    # default date for logging the spent time if the option is set
    spent_time_default_day = spent_time_field

    fields_map = {}
    params[:fields_map].each { |k, v| fields_map[k.unpack('U*').pack('U*')] = v }
    unique_attr = fields_map[unique_field]

    default_tracker = params[:default_tracker]
    journal_field = params[:journal_field]

    # attrs_map is fields_map's invert
    @attrs_map = fields_map.invert

    # validation!
    # if the unique_attr is blank but any of the following opts is turned on,
    if unique_attr.blank?
      if update_issue
        flash[:error] = l(:text_rmi_specify_unique_field_for_update)
      elsif @attrs_map["parent_issue"].present?
        flash[:error] = l(:text_rmi_specify_unique_field_for_column,
                          :column => l(:field_parent_issue))
      else IssueRelation::TYPES.each_key.any? { |t| @attrs_map[t].present? }
        IssueRelation::TYPES.each_key do |t|
          if @attrs_map[t].present?
            flash[:error] = l(:text_rmi_specify_unique_field_for_column,
                              :column => l("label_#{t}".to_sym))
          end
        end
      end
    end

    # validate that the id attribute has been selected
    if use_issue_id
      if @attrs_map["id"].blank?
        flash[:error] = l(:error_importer_id_mapping)
      end
    end

    # if error is full, NOP
    return if flash[:error].present?


    csv_opt = {:headers=>true,
               :quote_char=>iip.quote_char,
               :col_sep=>iip.col_sep}
    # Catch CSV read errors
    begin
      CSV.new(iip.csv_data, csv_opt).each do |row|
        project = Project.find_by(name: fetch("project", row))
        project ||= @project
    
        begin
          row.each do |k, v|
            k = k.unpack('U*').pack('U*') if k.kind_of?(String)
            v = v.unpack('U*').pack('U*') if v.kind_of?(String)
  
            row[k] = v
          end
  
          issue = Issue.new
  
          if use_issue_id && !row[unique_field].nil?
            issue.id = row[unique_field]
          end
  
          tracker_name = fetch("tracker", row)
          if !tracker_name.nil?
            tracker_id = Tracker.all.select{|s| s.name == tracker_name }.first.try(:id)
            if (@attrs_map["tracker"].present? && !tracker_id) 
              @messages << l(:error_importer_enumfield_not_found, id: row[unique_field], field_name: l(:field_tracker))
            end
          else
            tracker_id = nil
          end
          status_name = fetch("status", row)
          if !status_name.nil?
            status = IssueStatus.all.select{|s| s.name == status_name }.first
            if (@attrs_map["status"].present? && !status) 
              @messages << l(:error_importer_enumfield_not_found, id: row[unique_field], field_name: l(:field_status))
            end
          else
            status = nil
          end
          author = if @attrs_map["author"]
                     user_for_login(fetch("author", row))
                   else
                     User.current
                   end
          priority_name = fetch("priority", row)
          if !priority_name.nil?
            priority_id = IssuePriority.all.select{|s| s.name == priority_name }.first.try(:id)
            if (@attrs_map["priority"].present? && !priority_id) 
              @messages << l(:error_importer_enumfield_not_found, id: row[unique_field], field_name: l(:field_priority))
            end
          else
            priority_id = nil
          end
          category_name = fetch("category", row)
          category = IssueCategory.named(category_name).find_by(project_id: project.id)
  
          if (!category) \
            && category_name && category_name.length > 0 \
            && add_categories
  
            category = project.issue_categories.build(:name => category_name)
            category.save
          end
  
          if fetch("assigned_to", row).present?
            assigned_to = user_for_login(fetch("assigned_to", row))
          else
            assigned_to = nil
          end
  
          if fetch("fixed_version", row).present?
            fixed_version_name = fetch("fixed_version", row)
            fixed_version_id = version_id_for_name(project,
                                                    fixed_version_name,
                                                    add_versions)
          else
            fixed_version_name = nil
            fixed_version_id = nil
          end
  
          watchers = fetch("watchers", row)
  
          issue.project_id = project != nil ? project.id : @project.id
          issue.tracker_id = tracker_id != nil ? tracker_id : default_tracker
          issue.author_id = author != nil ? author.id : User.current.id
        rescue ActiveRecord::RecordNotFound
          log_failure(row, l(:error_importer_record_not_found, error_pos: @failed_count+1, unfound_class: @unfound_class, unfound_key: @unfound_key))
        end
  
        begin
          unique_attr = translate_unique_attr(issue, unique_field, unique_attr, unique_attr_checked)
  
          issue, journal = handle_issue_update(issue, row, author, status, update_other_project, journal_field,
                                               unique_attr, unique_field, ignore_non_exist, update_issue, allow_closed_issues_update)
  
          project ||= Project.find_by(id: issue.project_id)
  
          update_project_issues_stat(project)
  
          assign_issue_attrs(issue, category, fixed_version_id, assigned_to, status, row, priority_id)
          handle_parent_issues(issue, row, ignore_non_exist, unique_attr)
          handle_custom_fields(add_versions, issue, project, row)
          handle_watchers(issue, row, watchers)
          handle_spent_time(issue, project, row, spent_time_default_day)
        rescue RowFailed
          next
        end
  
        begin
          issue_saved = issue.save
        rescue ActiveRecord::RecordNotUnique
          issue_saved = false
          @messages << l(:error_importer_id_already_exists)
        rescue => error
          if ActiveRecord.const_defined?(:DeadlockVictim) and
            error.is_a?(ActiveRecord::DeadlockVictim)
            # retry once in case we were just unlucky
            issue_saved = issue.save
          else
            raise
          end
        end
  
  
        if !issue_saved
          @failed_count += 1
          @failed_issues[@failed_count] = row
          @messages << l(:error_importer_data_validation_failed, error_pos: @failed_count)
          issue.errors.each do |attr, error_message|
            @messages << l(:error_importer) + attr.to_s + " " + error_message.to_s
          end
        else
          if unique_field && !row[unique_field].nil?
            @issue_by_unique_attr[row[unique_field]] = issue
          end

          # Issue relations
          begin
            IssueRelation::TYPES.each_pair do |rtype, rinfo|
              if !row[@attrs_map[rtype]]
                next
              end
              other_issue = issue_for_unique_attr(unique_attr,
                                                  row[@attrs_map[rtype]],
                                                  row)
              relations = issue.relations.select do |r|
                (r.other_issue(issue).id == other_issue.id) \
                  && (r.relation_type_for(issue) == rtype)
              end
              if relations.length == 0
                relation = IssueRelation.new(:issue_from => issue,
                                             :issue_to => other_issue,
                                             :relation_type => rtype)
                relation.save
              end
            end
          rescue NoIssueForUniqueValue
            if ignore_non_exist
              @skip_count += 1
              next
            end
          rescue MultipleIssuesForUniqueValue
            break
          end
  
          if journal
            journal
          end
  
          @handle_count += 1
        end
      end # do
    rescue CSV::MalformedCSVError => e
      flash[:error] = l(:error_importer_csv_malformed, csv_error: e.message).html_safe
      redirect_to project_importer_path(:project_id => @project)
      return
    end

    if @failed_issues.size > 0
      @failed_issues = @failed_issues.sort
      @headers = @failed_issues[0][1].headers
    end

    # Clean up after ourselves
    iip.delete

    # Garbage prevention: clean up iips older than 3 days
    ImportInProgress.delete_all(["created < ?",Time.new - 3*24*60*60])
  end

  private

  def init_globals
    @handle_count = 0
    @update_count = 0
    @skip_count = 0
    @failed_count = 0
    @failed_issues = Hash.new
    @messages = Array.new
    @affect_projects_issues = Hash.new
    # This is a cache of previously inserted issues indexed by the value
    # the user provided in the unique column
    @issue_by_unique_attr = Hash.new
    # Cache of user id by login
    @user_by_login = Hash.new
    # Cache of Version by name
    @version_id_by_name = Hash.new
  end

  def translate_unique_attr(issue, unique_field, unique_attr, unique_attr_checked)
    # translate unique_attr if it's a custom field -- only on the first issue
    if !unique_attr_checked
      if unique_field && !ISSUE_ATTRS.include?(unique_attr.to_sym)
        issue.available_custom_fields.each do |cf|
          if cf.name == unique_attr
            unique_attr = "cf_#{cf.id}"
            break
          end
        end
      end
      unique_attr_checked = true
    end
    unique_attr
  end

  def handle_issue_update(issue, row, author, status, update_other_project, journal_field, unique_attr, unique_field, ignore_non_exist, update_issue, allow_closed_issues_update)
    if update_issue
      begin
        issue = issue_for_unique_attr(unique_attr, row[unique_field], row)

        # ignore other project's issue or not
        if issue.project_id != @project.id && !update_other_project
          @skip_count += 1
          @messages << l(:error_importer_row_skipped, id: row[unique_field], reason: l(:error_importer_other_project_forbidden))
          raise RowFailed
        end

        # ignore closed issue except reopen, or not
        if issue.status.is_closed? && !allow_closed_issues_update
          if status == nil || status.is_closed?
            @skip_count += 1
            @messages << l(:error_importer_row_skipped, id: row[unique_field], reason: l(:error_importer_issue_closed))
            raise RowFailed
          end
        end

        # init journal
        note = row[journal_field] || ''
        user_for_note = User.current
        # If there is a non-empty note, we use the field "user_for_spent_time" for the author of changes. Otherwise, we set it to the user running the import
        if !note.empty?
          begin
            user_for_note = user_for_login(fetch("user_for_spent_time", row))
          rescue ActiveRecord::RecordNotFound
          end
        end
        journal = issue.init_journal(user_for_note, note || '')

        @update_count += 1

      rescue NoIssueForUniqueValue
        if ignore_non_exist
          @skip_count += 1
          @messages << l(:error_importer_row_skipped, id: row[unique_field], reason: l(:error_importer_issue_not_found))
          raise RowFailed
        else
          # We create the entry if the ID was null, we raise an error if it was not null and could not be found
          if !row[unique_field].nil? 
            log_failure(row, l(:error_importer_update_failed_no_match, error_pos: @failed_count+1, value: row[unique_field]))
            raise RowFailed
          end
        end

      rescue MultipleIssuesForUniqueValue
        log_failure(row, l(:error_importer_update_failed_multiple, error_pos: @failed_count+1, value: row[unique_field]))
        raise RowFailed
      end
    end
    return issue, journal
  end

  def update_project_issues_stat(project)
    if @affect_projects_issues.has_key?(project.name)
      @affect_projects_issues[project.name] += 1
    else
      @affect_projects_issues[project.name] = 1
    end
  end

  def assign_issue_attrs(issue, category, fixed_version_id, assigned_to, status, row, priority_id)
    # required attributes
    issue.status_id = status != nil ? status.id : issue.status_id
    issue.priority_id = priority_id
    issue.subject = fetch("subject", row) || issue.subject

    # optional attributes
    issue.description = fetch("description", row) || issue.description
    issue.category_id = category != nil ? category.id : issue.category_id

    if fetch("start_date", row).present?
      issue.start_date = Date.parse(fetch("start_date", row))
    end
    issue.due_date = if row[@attrs_map["due_date"]].blank?
                       nil
                     else
                       Date.parse(row[@attrs_map["due_date"]])
                     end
    issue.assigned_to_id = assigned_to.id if assigned_to
    issue.fixed_version_id = fixed_version_id if fixed_version_id
    issue.done_ratio = row[@attrs_map["done_ratio"]] || issue.done_ratio
    issue.estimated_hours = row[@attrs_map["estimated_hours"]] || issue.estimated_hours
  end

  def handle_parent_issues(issue, row, ignore_non_exist, unique_attr)
    begin
      parent_value = row[@attrs_map["parent_issue"]]
      if parent_value.present?
        issue.parent_issue_id = issue_for_unique_attr(unique_attr, parent_value, row).id
      end
    rescue NoIssueForUniqueValue
      if ignore_non_exist
        @skip_count += 1
        @messages << l(:error_importer_row_skipped, id: row[unique_field], reason: l(:error_importer_issue_not_found))
      else
      log_failure(row, l(:error_importer_parent_set_failed_no_match, error_pos: @failed_count, value: parent_value))
        raise RowFailed
      end
    rescue MultipleIssuesForUniqueValue
      log_failure(row, l(:error_importer_parent_set_failed_multiple, error_pos: @failed_count, value: parent_value))
      raise RowFailed
    end
  end

  def handle_watchers(issue, row, watchers)
    watcher_failed_count = 0
    if watchers
      addable_watcher_users = issue.addable_watcher_users
      watchers.split(',').each do |watcher|
        begin
          watcher_user = user_for_login(watcher.strip)
          if issue.watcher_users.include?(watcher_user)
            next
          end
          if addable_watcher_users.include?(watcher_user)
            issue.add_watcher(watcher_user)
          end
        rescue ActiveRecord::RecordNotFound
          if watcher_failed_count == 0
            @failed_count += 1
            @failed_issues[@failed_count] = row
          end
          watcher_failed_count += 1
          @messages << l(:error_importer_add_watcher_failed, error_pos: @failed_count, user: watcher)
        end
      end
    end
    raise RowFailed if watcher_failed_count > 0
  end

  def handle_custom_fields(add_versions, issue, project, row)
    custom_failed_count = 0
    issue.custom_field_values = issue.available_custom_fields.inject({}) do |h, cf|
      value = row[@attrs_map[cf.name]]
      unless value.blank?
        if cf.multiple
          h[cf.id] = process_multivalue_custom_field(project, issue, cf, value, add_versions)
        else
          begin
            value = case cf.field_format
                      when 'user'
                        user_id_for_login(value).to_s
                      when 'version'
                        version_id_for_name(project, value, add_versions).to_s
                      when 'date'
                        value.to_date.to_s(:db)
                      when cf.field_format == 'list', 'enumeration'
                        value.split(',').map(&:strip)
                      else
                        value
                    end
            h[cf.id] = cf.value_from_keyword(value, issue)
          rescue
            if custom_failed_count == 0
              custom_failed_count += 1
              @failed_count += 1
              @failed_issues[@failed_count] = row
            end
            @messages << l(:error_importer_custom_field_set_failed, cf_name: cf.name, error_pos: @failed_count, value: value)
          end
        end
      end
      h
    end
    raise RowFailed if custom_failed_count > 0
  end

  def handle_spent_time(issue, project, row, spent_time_default_day)
    if fetch("spent_time", row).present?
      activity_id = activity_id_for_name(fetch("activity", row))
      begin
        user_for_spent_time = user_for_login(fetch("user_for_spent_time", row))
      rescue ActiveRecord::RecordNotFound
        user_for_spent_time = User.find_by(id: issue.assigned_to_id)
      end
      spent_time = fetch("spent_time", row)
      if (spent_time =~ /\A[-+]?[0-9]*\.?[0-9]+\Z/) && issue.id
        @time_entry = TimeEntry.new(
          :project => project,
          :issue => issue, 
          :user => user_for_spent_time,
          :spent_on => spent_time_default_day,
          :hours => spent_time,
          :comments => l(:default_comment_spent_time))
        @time_entry.safe_attributes = { :project_id => project.id, :issue_id => issue.id, :activity_id => activity_id }
        if !@time_entry.save
          @messages << l(:error_importer_spent_time_failed, spent_time: spent_time, id: issue.id)
        end
      else
        @messages << l(:error_importer_spent_time_invalid, spent_time: spent_time, id: issue.id)
      end
    end
  end

  def fetch(key, row)
    row[@attrs_map[key]]
  end

  def log_failure(row, msg)
    @failed_count += 1
    @failed_issues[@failed_count] = row
    @messages << msg
  end

  def find_project
    @project = Project.find(params[:project_id])
  end

  def flash_message(type, text)
    flash[type] ||= ""
    flash[type] += "#{text}<br/>"
  end

  def validate_csv_data(csv_data)
    if csv_data.lines.to_a.size <= 1
      flash[:error] = l(:error_importer_empty_csv).html_safe + csv_data

      redirect_to project_importer_path(:project_id => @project)

      return
    end
  end

  def sample_data(iip)
    # display sample
    sample_count = 5
    @samples = []
    begin
      CSV.new(iip.csv_data, { :headers => true,
                             :quote_char => iip.quote_char,
                             :col_sep => iip.col_sep }
            ).each_with_index do |row, i|
                @samples[i] = row
                break if i >= sample_count
              end # do

    rescue CSV::MalformedCSVError => e
      csv_data_lines = iip.csv_data.lines.to_a

      error_message = e.message +
        '<br/><br/>Header :<br/>'.html_safe +
        csv_data_lines[0]

      # if there was an exception, probably happened on line after the last sampled.
      if csv_data_lines.size > 0
        error_message += "<br/><br/>".html_safe + l(:error_importer_csv_header).html_safe + "<br/>".html_safe + 
          csv_data_lines[@samples.size + 1]
      end

      flash[:error] = error_message
      redirect_to project_importer_path(:project_id => @project)
      return
    end
  end

  def set_csv_headers(iip)
    if @samples.size > 0
      @headers = @samples[0].headers
    end

    missing_header_columns = ''
    @headers.each_with_index{|h, i|
      if h.nil?
        missing_header_columns += " #{i+1}"
      end
    }

    if missing_header_columns.present?
      flash[:error] = l(:error_importer_missing_header_columns, 
                        missing_header_columns: missing_header_columns, 
                        header_size: @headers.size,
                        header_name: iip.csv_data.lines[0])

      redirect_to project_importer_path(:project_id => @project)

      return
    end

  end

  # Returns the issue object associated with the given value of the given attribute.
  # Raises NoIssueForUniqueValue if not found or MultipleIssuesForUniqueValue
  def issue_for_unique_attr(unique_attr, attr_value, row_data)
    if @issue_by_unique_attr.has_key?(attr_value)
      return @issue_by_unique_attr[attr_value]
    end

    if unique_attr == "id"
      issues = [Issue.find_by(id: attr_value)]
    else
      # Use IssueQuery class Redmine >= 2.3.0
      begin
        if Module.const_get('IssueQuery') && IssueQuery.is_a?(Class)
          query_class = IssueQuery
        end
      rescue NameError
        query_class = Query
      end

      query = query_class.new(:name => "_importer", :project => @project)
      query.add_filter("status_id", "*", [1])
      query.add_filter(unique_attr, "=", [attr_value])

      issues = Issue.find :all,
        :conditions => query.statement,
        :limit => 2,
        :include => [ :assigned_to, :status, :tracker, :project, :priority,
                      :category, :fixed_version ]
    end

    if issues.size > 1
      log_failure(row_data, l(:error_importer_duplicate_key_field, field_name: unique_attr, value: attr_value, error_pos: @failed_count))
      raise MultipleIssuesForUniqueValue, "Unique field #{unique_attr} with" \
        " value '#{attr_value}' has duplicate record"
    elsif issues.size == 0 || issues.first.nil?
      raise NoIssueForUniqueValue, "No issue with #{unique_attr} of '#{attr_value}' found"
    else
      issues.first
    end
  end

  # Returns the id for the given user or raises RecordNotFound
  # Implements a cache of users based on login name
  def user_for_login(login)
    if login.nil?
      raise ActiveRecord::RecordNotFound
    else
      login = login.downcase unless login.nil?
    end
    begin
      if !@user_by_login.has_key?(login)
        @user_by_login[login] = User.find_by!(login: login)
      end
    rescue ActiveRecord::RecordNotFound
    # Try with the full name (first + last or just last), as this is what Redmine displays in lists
      new_cache_user = nil
      if login.match(/ /)
        firstname, lastname = *(login.split) # "First Last Throwaway"
        new_cache_user ||= User.all.detect {|a|
                       a.is_a?(User) && a.firstname.to_s.downcase == firstname &&
                         a.lastname.to_s.downcase == lastname
                     }
      end
      if new_cache_user.nil?
        new_cache_user ||= User.all.detect {|a| a.name.downcase == login}
      end
      if !new_cache_user.nil?
        @user_by_login[login] = new_cache_user
      else
        if params[:use_anonymous]
          @user_by_login[login] = User.anonymous()
        else
          @unfound_class = "User"
          @unfound_key = login
          raise
        end
      end
    end
    @user_by_login[login]
  end

  def user_id_for_login(login)
    user = user_for_login(login)
    user ? user.id : nil
  end


  # Returns the id for the given version or raises RecordNotFound.
  # Implements a cache of version ids based on version name
  # If add_versions is true and a valid name is given,
  # will create a new version and save it when it doesn't exist yet.
  def version_id_for_name(project,name,add_versions)
    if !@version_id_by_name.has_key?(name)
      version = project.shared_versions.find_by(name: name)
      if !version
        if name && (name.length > 0) && add_versions
          version = project.versions.build(:name=>name)
          version.save
        else
          @unfound_class = "Version"
          @unfound_key = name
          raise ActiveRecord::RecordNotFound, "No version named #{name}"
        end
      end
      @version_id_by_name[name] = version.id
    end
    @version_id_by_name[name]
  end

  def activity_id_for_name(activity)
    if activity.nil?
      if default_activity = TimeEntryActivity.default
        activity_id = default_activity.id
      end
    else
      activity_id = TimeEntryActivity.named(activity)
    end
    activity_id
  end

  def process_multivalue_custom_field(project, issue, custom_field, csv_val, add_versions)
    values = csv_val.split(',').map(&:strip)
    if custom_field.field_format == 'version'
      values.map do |val|
        version_id_for_name(project, val, add_versions)
      end
    else
      custom_field.value_from_keyword(values.join(","), issue)
    end
  end

  class RowFailed < StandardError
  end

end
