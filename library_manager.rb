# $autorun
#!/usr/bin/env ruby
# library_manager.rbm
# Adds a Library Manager toolbar with:
# - Load Libraries...
# - Save Library-Filtered Layout...
# - Re-Link Library Instances...
# Auto-loads libs.json from the process working directory (Dir.pwd).

require "json"

include RBA

# Keep actions in global array so they aren't garbage-collected
$library_manager_actions = []

# ---------------------------
# Shared: load libs from JSON
# ---------------------------
def load_libs_from_json(json_path, silent: false)
  unless File.exist?(json_path)
    puts "Library Manager: libs.json not found at #{json_path}" unless silent
    return 0
  end

  raw = nil
  begin
    raw = JSON.parse(File.read(json_path))
    raise "JSON must be a non-empty object" unless raw.is_a?(Hash) && raw.any?
  rescue => e
    msg = "Invalid JSON: #{e}"
    silent ? (puts "Library Manager: #{msg}") : MessageBox.critical("Library Manager", msg, MessageBox::b_ok)
    return 0
  end

  count = 0
  raw.each do |name, path|
    next if name.to_s.strip.empty? || !File.exist?(path.to_s)
    lib = Library.new
    lib.layout.read(path)
    lib.description = "Library #{name}"
    lib.register(name)
    count += 1
    puts "Registered #{name} → #{path}"
  end

  MessageBox.info("Library Manager", "Loaded #{count} libraries.", MessageBox::b_ok) unless silent
  count
end

def cwd_libs_json
  # Priority: explicit env var > current working dir > script dir (fallback)
  env_path = ENV["KLAYOUT_LIBS_JSON"]
  return env_path if env_path && !env_path.empty?
  return File.join(Dir.pwd, "libs.json") if Dir.pwd && !Dir.pwd.empty?
  File.expand_path("libs.json", __dir__)
end

# ---------------------------
# Action: Load Libraries...
# ---------------------------
load_action = Action.new
load_action.title = "Load Libraries..."
load_action.shortcut = "Ctrl+L"
load_action.on_triggered do
  start_dir = Dir.pwd || "."
  dlg = FileDialog.get_open_file_name("Select libs.json", start_dir, "JSON files (*.json);;All files (*)")
  unless dlg.has_value?
    MessageBox.info("Library Manager", "No JSON selected.", MessageBox::b_ok)
    next
  end
  load_libs_from_json(dlg.value, silent: false)
end
$library_manager_actions << load_action

# -------------------------------------
# Action: Save Library-Filtered Layout…
# -------------------------------------
save_lib_action = Action.new
save_lib_action.title = "Save Library-Filtered Layout..."
save_lib_action.shortcut = "Ctrl+Shift+S"
save_lib_action.on_triggered do
  mw = Application.instance.main_window
  cv = mw&.current_view
  unless cv
    MessageBox::warning("Library Manager", "No layout open!", MessageBox::Ok)
    next
  end
  layout = cv.active_cellview.layout

  # Prompt for output filename
  start_dir = Dir.pwd || "."
  outfile = FileDialog::ask_save_file_name(
    "Save filtered layout as", start_dir, "GDS files (*.gds);;OASIS files (*.oas)"
  )
  if outfile.nil?
    MessageBox::info("Library Manager", "Save canceled.", MessageBox::Ok)
    next
  end

  # Identify library cells and rename them
  lib_cells = layout.each_cell.select { |c| c.is_library_cell? || c.is_proxy? }
  lib_cells.each do |c|
    old_name = c.name
    lib_name  = c.qname.split(".").first || "LIB"
    new_name = "#{lib_name}___#{old_name}"
    layout.rename_cell(c.cell_index, new_name)
    puts "Renamed cell idx=#{c.cell_index}: '#{old_name}' → '#{new_name}'"
  end

  # Prepare save options
  opts = SaveLayoutOptions.new
  opts.gds2_write_cell_properties = true
  opts.write_context_info = true

  opts.clear_cells
  layout.top_cells.each { |c| opts.add_this_cell(c.cell_index) }
  (layout.each_cell.to_a - lib_cells).each { |c| opts.add_this_cell(c.cell_index) }
  opts.keep_instances = true
  opts.select_all_layers

  # Write out the layout
  layout.write(outfile, opts)
  MessageBox::info("Library Manager", "Layout saved to:\n#{outfile}", MessageBox::Ok)
end
$library_manager_actions << save_lib_action

# ---------------------------------
# Action: Re-Link Library Instances
# ---------------------------------
relink_action = Action.new
relink_action.title    = "Re-Link Library Instances..."
relink_action.shortcut = "Ctrl+Shift+O"
relink_action.on_triggered do
  app = RBA::Application.instance
  mw  = app.main_window

  # Ensure a layout is open
  unless mw.current_view
    start_dir = Dir.pwd || "."
    layout_path = FileDialog::ask_open_file_name("Select layout to relink", start_dir, "GDS/OAS files (*.gds *.oas)")
    if layout_path.nil?
      MessageBox::info("Library Manager", "No layout selected.", MessageBox::Ok)
      next
    end
    mw.load_layout(layout_path, 0)
  end

  cv     = mw.current_view
  layout = cv.active_cellview.layout

  # Collect all used qnames in the layout
  used_qnames = layout.each_cell.map(&:qname)
  puts "⚙️ Used cell qnames in layout:"
  used_qnames.each { |qn| puts "  - #{qn}" }

  # Map only those cells from libraries
  lib_map = {}
  Library.library_names.each do |lib_name|
    lib = Library.library_by_name(lib_name)
    next unless lib && lib.layout
    lib.layout.each_cell do |lc|
      next unless used_qnames.include?("#{lib_name}___#{lc.qname}")
      lib_map["#{lib_name}___#{lc.qname}"] = layout.add_lib_cell(lib, lc.cell_index)
    end
  end

  if lib_map.empty?
    MessageBox::warning("Library Manager", "No matching library cells found in the layout.", MessageBox::Ok)
    next
  end

  # Replace instances
  count = 0
  cells_to_remove = []
  layout.start_changes
  layout.each_cell do |parent|
    parent.each_inst.to_a.each do |inst|
      qn = inst.cell.qname
      cn = inst.cell.cell_index
      next unless lib_map.key?(qn)
      new_inst = CellInstArray.new(lib_map[qn], inst.trans, inst.a, inst.b, inst.na, inst.nb)
      inst.delete
      parent.insert(new_inst)
      cells_to_remove << cn
      count += 1
    end
  end

  cells_to_remove.each { |c| layout.delete_cell(c) }

  layout.end_changes
  cv.show_layout(layout, false)

  MessageBox::info("Library Manager", "Re-linked #{count} instances to library cells.", MessageBox::Ok)
  layout.refresh
  mw.redraw
end
$library_manager_actions << relink_action

# ---------------------------
# Insert menu + toolbar items
# ---------------------------
app = Application.instance
menu = app.main_window.menu

icon_path_load  = File.expand_path("lib_manager.png",  __dir__)
icon_path_save  = File.expand_path("save-icon.png",    __dir__)
icon_path_open  = File.expand_path("open-file.png",    __dir__)

load_action.icon          = icon_path_load
load_action.icon_text     = "Load Libraries"
save_lib_action.icon      = icon_path_save
save_lib_action.icon_text = "Save Library"
relink_action.icon        = icon_path_open
relink_action.icon_text   = "Open Library"

menu.insert_separator("@toolbar.end", "library_manager_sep")
menu.insert_item("@toolbar.end", "load_libraries",  load_action)
menu.insert_item("@toolbar.end", "save_library",    save_lib_action)
menu.insert_item("@toolbar.end", "open_libarary",   relink_action)

# ---------------------------
# Auto-load libs.json at boot
# ---------------------------
begin
  # Prefer the working directory used to launch KLayout
  default_libs = cwd_libs_json
  loaded = load_libs_from_json(default_libs, silent: true)
  puts "Library Manager: auto-loaded #{loaded} libraries from #{default_libs}"
rescue => e
  puts "Library Manager: auto-load failed: #{e}"
end
