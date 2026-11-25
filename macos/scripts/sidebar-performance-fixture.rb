# Run with a scratch output directory to write the fixture, and with --serve
# in the guest while running --ararat-sbperf-check and --ararat-sbperf-restore.
require "json"
require "fileutils"
require "socket"

port = 18765
if ARGV == ["--serve"]
  server = TCPServer.new("127.0.0.1", port)
  $stdout.sync = true
  puts "ready"
  loop do
    Thread.new(server.accept) do |socket|
      begin
        path = socket.gets&.split&.at(1)
        while (header = socket.gets) && header != "\r\n"
        end
        next unless path

        if (match = %r{\A/(\d+)/(\d+)\z}.match(path))
          body = %(<title>Loaded tab-#{match[1]}-#{match[2]}</title><link rel="icon" href="/icon.svg"><img src="/slow.svg?#{path}">)
          type = "text/html"
        else
          sleep 0.75 if path.start_with?("/slow.svg?")
          body = '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><rect width="16" height="16" fill="navy"/></svg>'
          type = "image/svg+xml"
        end
        socket.write("HTTP/1.1 200 OK\r\nContent-Type: #{type}\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
      rescue IOError, SystemCallError
      ensure
        socket.close
      end
    end
  end
end

out = ARGV.fetch(0)
FileUtils.mkdir_p(out)
source = File.expand_path("../../core/ararat-core/tests/fixtures/arc-sidebar-synthetic.json", __dir__)
base = JSON.parse(File.read(source))
container = base.fetch("sidebar").fetch("containers").fetch(1)
template = container.fetch("spaces").fetch(1)
item_templates = Hash[*container.fetch("items")]
spaces = []
items = {}
24.times do |i|
  id = "space-#{i}"
  pin = "pin-#{i}"
  today = "today-#{i}"
  profile = i % 3 == 0 ? { "default" => true } :
    { "custom" => { "_0" => { "directoryBasename" => "Profile #{i % 3}" } } }
  spaces.concat([id, template.merge("id" => id, "title" => format("SBPerf %02d", i),
    "profile" => profile, "containerIDs" => ["pinned", pin, "unpinned", today])])
  [[pin, "pin-work"], [today, "today-work"]].each do |key, source|
    items[key] = item_templates.fetch(source).merge("id" => key, "childrenIds" => [],
      "data" => { "itemContainer" => { "containerType" => { "spaceItems" => { "_0" => id } } } })
  end
  if i < 11
    folder = "folder-#{i}"
    items[pin]["childrenIds"] << folder
    items[folder] = item_templates.fetch("folder-docs").merge("id" => folder,
      "parentID" => pin, "childrenIds" => [])
  end
  if i == 0
    items[pin]["childrenIds"] << "split-0"
    items["split-0"] = item_templates.fetch("split-1").merge("id" => "split-0", "parentID" => pin,
      "childrenIds" => [], "data" => { "splitView" => { "layoutOrientation" => "horizontal" } })
  end
  (i < 13 ? 10 : 9).times do |j|
    tab = "tab-#{i}-#{j}"
    parent = if i == 0 && (1..2).cover?(j)
      "split-0"
    elsif j == 0 || j > 5
      today
    elsif i < 11
      folder
    else
      pin
    end
    items[parent]["childrenIds"] << tab
    items[tab] = item_templates.fetch("tab-spec").merge("id" => tab, "parentID" => parent, "title" => nil,
      "data" => { "tab" => { "savedURL" => "http://127.0.0.1:#{port}/#{i}/#{j}", "savedTitle" => tab } })
  end
end
abort unless items.values.count { |row| row["data"].key?("tab") } == 229
container["spaces"] = spaces
container["items"] = items.flat_map { |k, v| [k, v] }
container["topAppsContainerIDs"] = []
File.write(File.join(out, "StorableSidebar.json"), JSON.generate(base))
expanded = 11.times.flat_map { |index| ["folder-#{index}", { expanded: {} }] }
File.write(File.join(out, "StorableWindows.json"), JSON.generate(windows: [{ expandedItems: expanded, itemLastActiveDates: [] }]))
