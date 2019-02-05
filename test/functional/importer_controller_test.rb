require File.expand_path('../../test_helper', __FILE__)

class ImporterControllerTest < ActionController::TestCase
  def setup
    @tracker = Tracker.generate!
    @project = Project.generate!
    @role = Role.generate!(:permissions => [:import])
    @user = create_user!(@role, @project)
    @iip = create_iip_for_multivalues!(@user)
    @issue = create_issue!(@project, @user)
    create_custom_fields!(@issue)
    create_versions!(@project)
    User.stubs(:current).returns(@user)
  end

  test 'should handle multiple values for versions' do
    assert issue_has_none_of_these_affected_versions?(@issue,
                                                      ['Admin', '2013-09-25'])
    post :result, build_params
    assert_response :success
    @issue.reload
    assert issue_has_all_these_affected_versions?(@issue, ['Admin', '2013-09-25'])
  end

  test 'should handle multiple values for tags' do
    assert issue_has_none_of_these_tags?(@issue, ['tag1', 'tag2'])
    post :result, build_params
    assert_response :success
    @issue.reload
    assert issue_has_all_these_tags?(@issue, ['tag1', 'tag2'])
  end

  test 'should handle single-value fields' do
    assert_equal 'foobar', @issue.subject
    post :result, build_params
    assert_response :success
    @issue.reload
    assert_equal 'barfooz', @issue.subject
  end

  test 'should create issue if none exists' do
    Issue.delete_all
    assert_equal 0, Issue.count
    post :result, build_params(:update_issue => nil,
                               :default_tracker => @tracker.id)
    assert_response :success
    assert_equal 1, Issue.count
    issue = Issue.first
    assert_equal 'barfooz', issue.subject
  end

  test 'should send email when "Send email notifications" checkbox is checked' do
    assert_equal 'foobar', @issue.subject

    assert_difference 'ActionMailer::Base.deliveries.size', 1 do
      post :result, build_params(:disable_send_emails => nil)
    end
    assert_response :success
    @issue.reload
    assert_equal 'barfooz', @issue.subject
  end

  test 'should NOT send email when "Send email notifications" checkbox is unchecked' do
    assert_equal 'foobar', @issue.subject

    assert_no_difference 'ActionMailer::Base.deliveries.size' do
      post :result, build_params(:disable_send_emails => 'true')
    end
    assert_response :success
    @issue.reload
    assert_equal 'barfooz', @issue.subject
  end

  protected

  def build_params(opts={})
    opts.reverse_merge(
      :import_timestamp => @iip.created.strftime("%Y-%m-%d %H:%M:%S"),
      :update_issue => 'true',
      :unique_field => '#',
      :project_id => @project.id,
      :fields_map => {
        '#' => 'id',
        'Subject' => 'subject',
        'Tags' => 'Tags',
        'Affected versions' => 'Affected versions',
        'Priority' => 'priority',
        'Tracker' => 'tracker',
        'Status' => 'status'
      }
    )
  end
  
  def issue_has_all_these_affected_versions?(issue, version_names)
    find_version_ids(version_names).all? do |version_to_find|
      versions_for(issue).include?(version_to_find)
    end
  end
  
  def issue_has_none_of_these_affected_versions?(issue, version_names)
    find_version_ids(version_names).none? do |version_to_find|
      versions_for(issue).include?(version_to_find)
    end
  end

  def find_version_ids(version_names)
    version_names.map do |name|
      Version.find_by_name!(name).id.to_s
    end
  end

  def versions_for(issue)
    versions_field = CustomField.find_by_name! 'Affected versions'
    value_objs = issue.custom_values.where(:custom_field => versions_field)
    values = value_objs.map(&:value)
  end
  
  def issue_has_all_these_tags?(issue, tags_to_find)
    tags_to_find.all? do |tag_to_find|
      tags_for(issue).include?(tag_to_find)
    end
  end
  
  def issue_has_none_of_these_tags?(issue, tags_to_find)
    tags_to_find.none? do |tag_to_find|
      tags_for(issue).include?(tag_to_find)
    end
  end

  def tags_for(issue)
    tags_field = CustomField.find_by_name! 'Tags'
    value_objs = issue.custom_values.where(:custom_field => tags_field)
    values = value_objs.map(&:value)
  end

  def create_user!(role, project)
    sponsor = User.generate! :admin => true,
                     :firstname => 'Alice',
                     :lastname => 'Hacker',
                     :mail => 'alice.hacker@example.com'
    sponsor.pref.no_self_notified = false
    user = User.generate! :admin => true,
                     :firstname => 'Bob',
                     :lastname => 'Loblaw',
                     :mail => 'bob.loblaw@example.com'
    user.pref.no_self_notified = false
    user.login = 'bob'
    membership = user.memberships.build(:project => project)
    membership.roles << role
    membership.principal = user
    user.save!
    user
  end

  def create_iip_for_multivalues!(user)
    create_iip!('CustomFieldMultiValues', user)
  end

  def create_iip!(filename, user)
    iip = ImportInProgress.new
    iip.user = user
    iip.csv_data = get_csv(filename)
    iip.created = DateTime.now
    iip.encoding = 'U'
    iip.col_sep = ','
    iip.quote_char = '"'
    iip.save!
    iip
  end

  def create_issue!(project, author)
    issue = Issue.new
    issue.id = 70385
    issue.project = project
    issue.subject = 'foobar'
    issue.create_priority!(name: 'Critical')
    issue.tracker = project.trackers.first
    issue.author = author
    issue.create_status!(name: 'New')
    issue.save!
    issue
  end

  def create_custom_fields!(issue)
    versions_field = create_multivalue_field!('Affected versions',
                                              'version',
                                              issue.project)
    tags_field =     create_multivalue_field!('Tags',
                                              'list',
                                              issue.project,
                                              %w(tag1 tag2))
    issue.tracker.custom_fields << versions_field
    issue.tracker.custom_fields << tags_field
    issue.tracker.save!
  end

  def create_multivalue_field!(name, format, project, possible_vals = [])
    field = IssueCustomField.new :name => name, :multiple => true
    field.field_format = format
    field.projects << project
    field.possible_values = possible_vals if possible_vals
    field.save!
    field
  end

  def create_versions!(project)
    project.versions.create! :name => 'Admin', :status => 'open'
    project.versions.create! :name => '2013-09-25', :status => 'open'
  end

  def get_csv(filename)
    File.read(File.expand_path("../../samples/#{filename}.csv", __FILE__))
  end
end
