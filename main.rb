require 'csv'
require 'fileutils'
require 'io/console'
require 'yaml'
require 'timeout'
require 'tty-prompt'
require 'tty-box'
require 'tty-table'
require 'pastel'
require 'tty-cursor'
require 'tty-screen'
require 'tty-font'
require 'tty-progressbar'
require 'time'

module Utilities
  def self.format_time(seconds)
    hours, remaining = seconds.divmod(3600)
    minutes, _ = remaining.divmod(60)
    "#{hours}h #{minutes}m"
  end

  def self.format_datetime(time)
    time.strftime("%Y-%m-%d %H:%M:%S")
  end

  def self.random_motivation_quote
    quotes = [
      "The secret of getting ahead is getting started. - Mark Twain",
      "It always seems impossible until it's done. - Nelson Mandela",
      "Don't watch the clock; do what it does. Keep going. - Sam Levenson",
      "The only way to do great work is to love what you do. - Steve Jobs",
      "Success is not final, failure is not fatal: it is the courage to continue that counts. - Winston Churchill"
    ]
    quotes.sample
  end

  def self.ascii_bar_chart(data, width = 50)
    max_value = data.map { |_, v| v }.max.to_f
    pastel = Pastel.new
    data.map do |label, value|
      bar_width = (value / max_value * width).round
      bar = pastel.green('█' * bar_width) + pastel.black('░' * (width - bar_width))
      "#{label.ljust(10)} |#{bar}| #{value}"
    end.join("\n")
  end
end

class Task
  attr_reader :id, :title, :status, :pomodoros_completed, :total_pomodoro_time, :current_pomodoro_time, :created_at

  def initialize(id, title, status = 'pending', pomodoros_completed = 0, total_pomodoro_time = 0, current_pomodoro_time = 0, created_at = Time.now)
    @id = id
    @title = title
    @status = status
    @pomodoros_completed = pomodoros_completed
    @total_pomodoro_time = total_pomodoro_time
    @current_pomodoro_time = current_pomodoro_time
    @created_at = created_at
  end

  def add_time(duration)
    @current_pomodoro_time += duration.to_i
  end

  def complete_pomodoro
    @pomodoros_completed += 1
    @total_pomodoro_time += @current_pomodoro_time
    @current_pomodoro_time = 0
  end

  def mark_complete
    @status = 'completed'
  end

  def completed?
    @status == 'completed'
  end
end

class PomodoroTimer
  def initialize(todo_app, config)
    @todo_app = todo_app
    @config = config
    @pomodoro_count = 0
    @paused = false
    @stopped = false
    @prompt = TTY::Prompt.new
    @pastel = Pastel.new
    @cursor = TTY::Cursor
    @font = TTY::Font.new(:doom)
    @progress_bar = nil
    @session_start_time = nil
  end

  def start(task)
    if task.completed?
      puts @pastel.red("Cannot work on completed tasks.")
      return false
    end

    @stopped = false
    @session_start_time = Time.now
    display_start_info(task)
    time_worked = countdown(@config.work_duration, task)
    update_task_stats(task, time_worked)
    handle_pomodoro_completion(task) unless @stopped
    true
  end

  private

  def display_start_info(task)
    system('clear') || system('cls')
    puts @font.write("POMODORO")
    puts TTY::Box.frame(
      @pastel.bright_cyan("Starting Pomodoro for task: #{task.title}"),
      @pastel.bright_green(Utilities.random_motivation_quote),
      padding: 1,
      title: { top_left: ' 🍅 ', bottom_right: ' 🍅 ' }
    )
    puts "Notes file: #{@todo_app.notes_filename(task)}"
  end

  def handle_pomodoro_completion(task)
    task.complete_pomodoro
    @pomodoro_count += 1
    puts TTY::Box.success(@pastel.green("Pomodoro completed! Take a break."), padding: 1)
    @todo_app.add_notes(task)

    if @pomodoro_count % @config.pomodoros_before_long_break == 0
      handle_long_break
    else
      handle_short_break
    end

    puts TTY::Box.warn(@pastel.yellow("Break over. Ready for the next Pomodoro?"), padding: 1)
    @todo_app.save_tasks
  end

  def handle_long_break
    puts TTY::Box.info(@pastel.blue("Time for a long break!"), padding: 1)
    countdown(@config.long_break_duration)
  end

  def handle_short_break
    countdown(@config.break_duration)
  end

  def countdown(seconds, task = nil)
    start_time = Time.now
    end_time = start_time + seconds

    progress_bar = TTY::ProgressBar.new(
      "[:bar] :percent",
      total: seconds,
      width: 30,
      complete: @pastel.green('='),
      incomplete: @pastel.red('-')
    )

    print @cursor.hide

    loop do
      break if Time.now >= end_time || @stopped

      elapsed = (Time.now - start_time).to_i
      remaining = seconds - elapsed
      minutes, secs = remaining.divmod(60)

      task&.add_time(1) unless @paused

      # Clear the screen and redraw
      print @cursor.clear_screen
      print @cursor.move_to(0, 0)

      puts @pastel.bold(@font.write("POMODORO"))
      puts

      box_content = [
        @pastel.cyan("Task: #{task&.title}"),
        @pastel.yellow("Time left: #{format('%02d:%02d', minutes, secs)}"),
        @pastel.green("Progress:"),
        progress_bar.current.to_s
      ]

      puts TTY::Box.frame(*box_content, padding: 1, title: { top_left: ' 🍅 ', bottom_right: ' 🍅 ' })

      puts
      if @paused
        puts @pastel.yellow("PAUSED")
      end
      puts @pastel.dim("Press 'p' to pause/resume, 's' to stop, or 'c' to complete")

      progress_bar.advance(1) unless @paused
      handle_input(end_time, task)
      sleep 1
    end

    print @cursor.show
    puts "\n#{@pastel.red('Timer stopped.')}" if @stopped
    elapsed_time = [Time.now - start_time, seconds].min.to_i
    update_task_stats(task, elapsed_time) if @stopped
    elapsed_time
  end

  def handle_input(end_time, task)
    input = @prompt.keypress("", timeout: 0.1)
    case input
    when 'p'
      toggle_pause(end_time)
    when 's'
      @stopped = true
    when 'c'
      complete_task(task)
      @stopped = true
    end
  end

  def toggle_pause(end_time)
    @paused = !@paused
    if @paused
      @pause_start = Time.now
    else
      end_time += Time.now - @pause_start
    end
  end

  def complete_task(task)
    task.mark_complete
    @todo_app.save_tasks
    puts @pastel.green("Task marked as complete!")
  end

  def update_task_stats(task, time_worked)
    task.add_time(time_worked)
    @todo_app.update_stats(time_worked)
  end
end

class Config
  attr_accessor :work_duration, :break_duration, :long_break_duration, :pomodoros_before_long_break

  def initialize
    load_config
  end

  def load_config
    if File.exist?('config.yml')
      config = YAML.load_file('config.yml')
      @work_duration = config['work_duration'] || 25 * 60
      @break_duration = config['break_duration'] || 5 * 60
      @long_break_duration = config['long_break_duration'] || 15 * 60
      @pomodoros_before_long_break = config['pomodoros_before_long_break'] || 4
    else
      set_default_config
    end
  end

  def save_config
    config = {
      'work_duration' => @work_duration,
      'break_duration' => @break_duration,
      'long_break_duration' => @long_break_duration,
      'pomodoros_before_long_break' => @pomodoros_before_long_break
    }
    File.write('config.yml', config.to_yaml)
  end

  def set_default_config
    @work_duration = 25 * 60
    @break_duration = 5 * 60
    @long_break_duration = 15 * 60
    @pomodoros_before_long_break = 4
    save_config
  end
end

class TodoApp
  def initialize
    @tasks = load_tasks
    @next_id = @tasks.map(&:id).max.to_i + 1
    @config = Config.new
    @timer = PomodoroTimer.new(self, @config)
    @prompt = TTY::Prompt.new
    @pastel = Pastel.new
    @font = TTY::Font.new(:doom)
    @stats = load_stats
  end

  def run
    display_welcome_screen
    loop do
      display_dashboard
      handle_user_choice
    end
  end

  def notes_filename(task)
    "notes/task_#{task.id}_#{task.title.gsub(/[^0-9A-Za-z]/, '_')}.md"
  end

  def save_tasks
    CSV.open('tasks.csv', 'w') do |csv|
      csv << ['id', 'title', 'status', 'pomodoros_completed', 'total_pomodoro_time', 'current_pomodoro_time', 'created_at']
      @tasks.each { |task| csv << task_to_array(task) }
    end
  end


  def update_stats(time_worked)
    today = Date.today.to_s
    @stats[today] = (@stats[today] || 0) + time_worked
    save_stats
  end

  private

  def display_welcome_screen
    system('clear') || system('cls')
    puts @font.write("POMORUBY")
    puts TTY::Box.frame(
      @pastel.bright_cyan("Welcome to Pomoruby!"),
      @pastel.bright_green("Your personal Pomodoro-powered task manager."),
      padding: 1,
      title: { top_left: ' 🍅 ', bottom_right: '  ' }
    )
    sleep 2
  end

  def display_dashboard
    system('clear') || system('cls')
    puts @font.write("POMORUBY")
    display_stats
    display_tasks
    display_menu
  end

  def display_stats
    total_tasks = @tasks.count
    completed_tasks = @tasks.count(&:completed?)
    total_pomodoros = @tasks.sum(&:pomodoros_completed)
    total_time = @tasks.sum(&:total_pomodoro_time)

    stats = [
      "#{@pastel.cyan('Total tasks:')} #{total_tasks}",
      "#{@pastel.green('Completed tasks:')} #{completed_tasks}",
      "#{@pastel.yellow('Completion rate:')} #{(completed_tasks.to_f / total_tasks * 100).round(2)}%",
      "#{@pastel.magenta('Total Pomodoros:')} #{total_pomodoros}",
      "#{@pastel.blue('Total time:')} #{Utilities.format_time(total_time)}",
    ]

    puts TTY::Box.frame(*stats, title: { top_left: @pastel.bold.cyan('📊 Stats 📊') }, padding: 1, border: :thick)
  end

  def display_tasks
    if @tasks.empty?
      puts TTY::Box.frame(@pastel.yellow("No tasks available. Add a task to get started!"),
                          title: { top_left: '📝 Tasks 📝' },
                          padding: 1)
    else
      table = TTY::Table.new(
        header: ['ID', 'Status', 'Title', 'Pomodoros', 'Total Time', 'Current Time', 'Created At'],
        rows: @tasks.map { |task| task_to_row(task) }
      )
      rendered_table = table.render(:unicode, padding: [0, 1])
      if rendered_table.empty?
        puts TTY::Box.frame(@pastel.yellow("Error rendering tasks table."),
                            title: { top_left: '📝 Tasks 📝' },
                            padding: 1)
      else
        puts TTY::Box.frame(rendered_table,
                            title: { top_left: '📝 Tasks 📝' },
                            padding: 1)
      end
    end
  rescue => e
    puts TTY::Box.frame(@pastel.red("Error displaying tasks: #{e.message}"),
                        title: { top_left: '📝 Tasks 📝' },
                        padding: 1)
  end

  def display_menu
    menu_items = [
      { key: 'a', desc: 'Add task', color: :green },
      { key: 's', desc: 'Start Pomodoro', color: :yellow },
      { key: 'c', desc: 'Complete task', color: :blue },
      { key: 'd', desc: 'Delete task', color: :red },
      { key: 'n', desc: 'Open notes', color: :magenta },
      { key: 'u', desc: 'Update config', color: :cyan },
      { key: 'v', desc: 'View statistics', color: :bright_blue },
      { key: 'q', desc: 'Quit', color: :bright_red }
    ]

    menu = menu_items.map { |item| "#{@pastel.send(item[:color], item[:key])} - #{item[:desc]}" }.join(" | ")
    puts TTY::Box.frame(menu, title: { top_left: '🔧 Menu 🔧' }, padding: 1)
  end

  def handle_user_choice
    choice = @prompt.keypress("Enter your choice: ").downcase
    case choice
    when 'a' then add_task
    when 's' then start_pomodoro
    when 'c' then complete_task
    when 'd' then delete_task
    when 'n' then open_notes
    when 'u' then update_config
    when 'v' then view_statistics
    when 'q' then save_and_exit
    else puts @pastel.red("Invalid choice. Please try again.")
    end
  end

  def add_task
    title = @prompt.ask("Enter task title:")
    task = Task.new(@next_id, title)
    @tasks << task
    @next_id += 1
    save_tasks
    create_task_note_file(task)
    puts @pastel.green("Task added successfully!")
  end

  def start_pomodoro
    if @tasks.empty?
      puts @pastel.red("No tasks available. Add a task first.")
      return
    end

    task_id = @prompt.ask("Enter task ID to start Pomodoro:").to_i
    task = @tasks.find { |t| t.id == task_id }

    if task
      success = @timer.start(task)
      puts @pastel.yellow("Pomodoro cancelled.") unless success
    else
      puts @pastel.red("Invalid task ID. Please try again.")
    end
  end

  def complete_task
    task_id = @prompt.ask("Enter task ID to mark as complete:").to_i
    task = @tasks.find { |t| t.id == task_id }

    if task
      task.mark_complete
      save_tasks
      puts @pastel.green("Task marked as complete!")
    else
      puts @pastel.red("Invalid task ID. Please try again.")
    end
  end

  def delete_task
    task_id = @prompt.ask("Enter task ID to delete:").to_i
    task = @tasks.find { |t| t.id == task_id }

    if task
      @tasks.delete(task)
      save_tasks
      puts @pastel.green("Task deleted successfully!")
    else
      puts @pastel.red("Invalid task ID. Please try again.")
    end
  end

  def open_notes
    task_id = @prompt.ask("Enter task ID to open notes:").to_i
    task = @tasks.find { |t| t.id == task_id }

    if task
      filename = notes_filename(task)
      if File.exist?(filename)
        system("#{ENV['EDITOR'] || 'nano'} #{filename}")
      else
        puts @pastel.yellow("No notes file found for this task. Creating a new one.")
        create_task_note_file(task)
        system("#{ENV['EDITOR'] || 'nano'} #{filename}")
      end
    else
      puts @pastel.red("Invalid task ID. Please try again.")
    end
  end

  def update_config
    puts @pastel.cyan("Current configuration:")
    display_current_config

    update_config_values
    @config.save_config
    puts @pastel.green("Configuration updated successfully!")
  end

  def add_notes(task)
    filename = notes_filename(task)
    if @prompt.yes?("Would you like to add notes for this session?")
      notes = @prompt.multiline("Enter your notes (press Ctrl+D or enter a blank line when finished):")
      File.open(filename, 'a') do |file|
        file.puts "\n--- Notes from Pomodoro session ---"
        file.puts notes
      end
      puts @pastel.green("Notes added successfully!")
    end
  end

  def load_tasks
    tasks = []
    CSV.foreach('tasks.csv', headers: true) do |row|
      created_at = row['created_at'] ? Time.parse(row['created_at']) : Time.now
      tasks << Task.new(
        row['id'].to_i,
        row['title'],
        row['status'],
        row['pomodoros_completed'].to_i,
        row['total_pomodoro_time'].to_i,
        row['current_pomodoro_time'].to_i,
        created_at
      )
    end
    tasks
  rescue Errno::ENOENT
    []
  end

  def task_to_row(task)
    status_color = task.completed? ? :green : :yellow
    [
      task.id.to_s,
      @pastel.send(status_color, task.status.to_s),
      task.title.to_s,
      task.pomodoros_completed.to_s,
      Utilities.format_time(task.total_pomodoro_time),
      Utilities.format_time(task.current_pomodoro_time),
      Utilities.format_datetime(task.created_at)
    ]
  end

  def task_to_array(task)
    [task.id, task.title, task.status, task.pomodoros_completed, task.total_pomodoro_time, task.current_pomodoro_time, task.created_at]
  end

  def display_current_config
    puts "Work duration: #{@config.work_duration / 60} minutes"
    puts "Break duration: #{@config.break_duration / 60} minutes"
    puts "Long break duration: #{@config.long_break_duration / 60} minutes"
    puts "Pomodoros before long break: #{@config.pomodoros_before_long_break}"
  end

  def update_config_values
    @config.work_duration = @prompt.ask("Enter new work duration (in minutes):").to_i * 60
    @config.break_duration = @prompt.ask("Enter new break duration (in minutes):").to_i * 60
    @config.long_break_duration = @prompt.ask("Enter new long break duration (in minutes):").to_i * 60
    @config.pomodoros_before_long_break = @prompt.ask("Enter new number of pomodoros before long break:").to_i
  end

  def create_task_note_file(task)
    filename = notes_filename(task)
    FileUtils.mkdir_p(File.dirname(filename))
    File.open(filename, 'w') do |file|
      file.puts "# Notes for Task #{task.id}: #{task.title}"
      file.puts "Created at: #{Utilities.format_datetime(task.created_at)}"
      file.puts "\n"
    end
  end

  def view_statistics
    system('clear') || system('cls')
    puts @pastel.bold(@font.write("STATISTICS"))
    puts

    display_stats
    puts
    display_productivity_chart
    puts
    display_task_completion_rate

    @prompt.keypress("\n#{@pastel.dim('Press any key to continue')}")
  end

  def display_productivity_chart
    productivity_data = @stats.sort_by { |date, _| Date.parse(date) }
                          .last(7)
                          .to_h

    if productivity_data.empty?
      puts TTY::Box.frame(@pastel.yellow("No productivity data available for the last 7 days."),
                          title: { top_left: @pastel.bold.green('📈 Last 7 Days Productivity 📈') },
                          padding: 1,
                          border: :thick)
    else
      chart = Utilities.ascii_bar_chart(productivity_data)
      puts TTY::Box.frame(chart,
                          title: { top_left: @pastel.bold.green('📈 Last 7 Days Productivity 📈') },
                          padding: 1,
                          border: :thick)
    end
  end

  def display_task_completion_rate
    completed = @tasks.count(&:completed?)
    total = @tasks.count
    rate = (completed.to_f / total * 100).round(2)

    meter = TTY::ProgressBar.new("[:bar]", total: 100, width: 50, complete: '=', incomplete: ' ')
    meter.advance(rate)

    content = [
      "#{@pastel.yellow('Task Completion Rate:')} #{rate}%",
      meter.complete
    ]

    puts TTY::Box.frame(*content,
                        title: { top_left: @pastel.bold.yellow('🎯 Task Completion Rate 🎯') },
                        padding: 1,
                        border: :thick)
  end

  def save_and_exit
    save_tasks
    save_stats
    puts @pastel.green("Thank you for using Taskerer! Goodbye!")
    exit
  end

  def load_stats
    @stats = YAML.load_file('stats.yml') || {}
  rescue Errno::ENOENT
    @stats = {}
  end

  def save_stats
    File.write('stats.yml', @stats.to_yaml)
  end
end

# Run the application
TodoApp.new.run
