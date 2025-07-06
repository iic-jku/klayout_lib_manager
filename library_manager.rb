#!/usr/bin/env ruby
# library_manager.rbm
# Adds a top-level Library Manager menu with Load Libraries... and Prune Library Cells
require "json"

include RBA

# Keep actions in global array so they aren't garbage-collected
$library_manager_actions = []

# Define the "Load Libraries..." action
load_action = Action.new
load_action.title = "Load Libraries..."
load_action.shortcut = "Ctrl+L"
load_action.on_triggered do
  dlg = FileDialog.get_open_file_name("Select libs.json", ".", "JSON files (*.json);;All files (*)")
  unless dlg.has_value?
    MessageBox.info("Library Manager", "No JSON selected.", MessageBox::b_ok)
    next
  end

  begin
    raw = JSON.parse(File.read(dlg.value))
    raise unless raw.is_a?(Hash) && raw.any?
  rescue => e
    MessageBox.critical("Library Manager", "Invalid JSON: #{e}", MessageBox::b_ok)
    next
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

  MessageBox.info("Library Manager", "Loaded #{count} libraries.", MessageBox::b_ok)
end
$library_manager_actions << load_action

# Define the "Prune Library Cells" action
prune_action = Action.new
prune_action.title = "Prune Library Cells"
prune_action.shortcut = "Ctrl+P"
prune_action.on_triggered do
  mw = Application.instance.main_window
  cv = mw && mw.current_view
  unless cv
    MessageBox.warning("Library Manager", "No layout open!", MessageBox::b_ok)
    next
  end

  layout = cv.active_cellview.layout
  cells = layout.each_cell.select { |c| c.is_library_cell? || c.is_proxy? }
  if cells.empty?
    MessageBox.info("Library Manager", "No library/proxy cells found.", MessageBox::b_ok)
    next
  end

  indices = []
  cells.each do |c|
    puts "→ Preparing to delete cell: name='#{c.name}', qname='#{c.qname}', idx=#{c.cell_index}"
    indices << c.cell_index
  end

  layout.start_changes
  layout.delete_cells(indices)
  layout.end_changes

  MessageBox.info("Library Manager", "Deep prune completed.", MessageBox::b_ok)
end
$library_manager_actions << prune_action


save_lib_action = Action.new
save_lib_action.title = "Save Library‑Filtered Layout..."
save_lib_action.shortcut = "Ctrl+S"
save_lib_action.on_triggered do
  mw = Application.instance.main_window
  cv = mw&.current_view
  unless cv
    MessageBox::warning("Library Manager", "No layout open!", MessageBox::Ok)
    next
  end
  layout = cv.active_cellview.layout

  # Prompt user for output file
  outfile = FileDialog::ask_save_file_name(
    "Save filtered layout as", ".", "GDS files (*.gds);;OASIS files (*.oas)"
  )
  if outfile.nil?
    MessageBox::info("Library Manager", "Save canceled.", MessageBox::Ok)
    next
  end

  # Identify library/proxy cells
  lib_cells = layout.each_cell.select { |c| c.is_library_cell? || c.is_proxy? }
  if lib_cells.any?
    lib_cells.each do |c|
      puts "Excluding cell: idx=#{c.cell_index}, qname='#{c.qname}'"
    end
  else
    MessageBox::info("Library Manager", "No library cells found — full save.", MessageBox::Ok)
  end

  # Setup save options excluding library cells
  opts = SaveLayoutOptions.new
  opts.clear_cells
  layout.top_cells.each { |c| opts.add_cell(c.cell_index) }
  (layout.each_cell.to_a - lib_cells).each { |c| opts.add_cell(c.cell_index) }

  opts.keep_instances = true  # instances become "ghost" references :contentReference[oaicite:1]{index=1}
  
  opts.select_all_layers

  # Write the file
  layout.write(outfile, opts)
  MessageBox::info("Library Manager", "Layout saved to:\n#{outfile}", MessageBox::Ok)
end
$library_manager_actions << save_lib_action




# Insert the top-level menu and its sub-items
app = Application.instance
menu = app.main_window.menu

# Use an icon for toolbar buttons
icon_path_load  = File.expand_path("lib_manager.png",  __dir__)
icon_path_prune = File.expand_path("prune_icon.png", __dir__)

# Assign icons (you can skip icon_text if you want no text)
load_action.icon       = icon_path_load     # toolbar will show image
load_action.icon_text  = "Load Libraries"                # hide any text under icon (optional)
prune_action.icon      = icon_path_prune
prune_action.icon_text = "Prune Cells"

# Add to toolbar using unique identifiers
menu.insert_separator("@toolbar.end", "library_manager_sep")
menu.insert_item("@toolbar.end","load_libraries",load_action)
menu.insert_item("@toolbar.end","prune_cells",prune_action)
menu.insert_item("@toolbar.end", "save_library", save_lib_action)