require 'net/http'
require 'csv'

CURRENT_LLVM_VERSION="6.0.0"

class FormulaInfo
  attr_accessor :name, :vers, :platform, :rev, :desc, :url, :bottles, :rebuild, :deps
  def to_s
    s = "Formula name:#{@name} vers:#{@vers}"
    s += " rev:#{@rev}" unless @rev.nil?
    s += " rebuild:#{@rebuild}" unless @rebuild.nil?
    s
  end
end

class BottleInfo
  attr_accessor :host,:filename,:hash
  def initialize(host, filename, sha)
    @host = host
    @filename = filename
    @hash = sha
  end
  def to_s
    "Bottle filename:#{@filename}"
  end
end

class Wrangler
  attr_accessor :s3files, :formulas, :bottle_hosts, :bottles_available, :used_formulas,:deps
  def initialize
    @formulas = [] # array of FormulaInfo
    @bottle_hosts = {} # name => url
    @bottles_available = [] # array of BottleInfo
    @s3files = [] # filenames of parsed s3 directory
    @used_formulas = []
    @deps = []
  end

  def load_formula(dirpath,filename)
    info = FormulaInfo.new
    info.bottles = []
    info.deps = []
    info.name = filename.gsub('.rb','')
    File.open(File.join(dirpath,filename)) do |io|
      io.each_line do |line|
        key,val = line.strip.split(' ', 2)
        case key
        when 'desc'
          info.desc = val
        when 'url'
          info.url = val if info.url.nil?
        when 'version'
          info.vers = val.gsub('"','') if info.vers.nil?
        when 'revision'
          info.rev = val if info.rev.nil?
        when 'rebuild'   # inside bottle do
          info.rebuild = val
        when 'end'
          break
        when 'depends_on'
          depname,depmode = val.split('=>',2)
          if depmode.nil? || depmode.strip != ':build'
            info.deps.push depname.strip.gsub('"','')
          end
        when 'sha256'
          tmp = val.split('=>',2)
          if tmp.count == 2
            sha = tmp[0].strip.gsub('"','')
            distro = tmp[1].strip.gsub(':','')
            info.bottles.push [distro,sha]
          end
        else
        end
      end
    end
    info
  end

  def load_source_formulas(dirpath)
    Dir.new(dirpath).each do |f|
      next unless f.end_with?(".rb")
      info = load_formula dirpath, f
      if info.vers.nil? && !info.url.nil?
        info.vers = extract_version_from_url info.url, info.name
      end
      @formulas.push info
      #puts info.inspect
      #break
      #puts "formula name:#{info.name},#{info.vers}"
    end
  end

  # "https://ftp.gnu.org/gnu/autoconf/autoconf-2.69.tar.gz"
  # "https://pkgconfig.freedesktop.org/releases/pkg-config-0.29.2.tar.gz"
  # "https://github.com/miloyip/rapidjson/archive/v1.1.0.tar.gz"
  def extract_version_from_url url, name=nil
    s = url.gsub(/.*\//,'')
    s = s.gsub(/\.tar.*/,'')
    s = s.gsub(/^[a-zA-Z\-]*/,'')
    s = s.gsub(/^2-/,'')
    #s = s.gsub(/^2-/,'') if s.end_with?('2')
    s
  end

  def make_bottle_filename(info, distro)
    # hack workaround for llvm and libcpp files with variable version
    vers = info.vers
    vers = CURRENT_LLVM_VERSION if vers.include?("llvm_version")

    s = "#{info.name}-#{vers}"
    s += "_#{info.rev}" unless info.rev.nil?
    s += ".#{distro}.bottle"
    s += ".#{info.rebuild}" unless info.rebuild.nil?
    s += ".tar.gz"
    s
  end

  def dump_bottle_csv
    missing = 0
    @formulas.each do |info|
      info.bottles.each do |a|
        distro = a[0]
        sha = a[1]
        filename = make_bottle_filename(info,distro)
        puts "osquery,#{filename},#{sha}"
        unless @s3files.include?(filename)
          puts "_MISSING,--^^^^--"
          missing += 1
        end
      end
    end
    return missing
  end

  def load_bottles_csv(filepath)
    CSV.foreach(filepath,"r") do |row|
      next if row.count <= 1
      next if row[0].start_with?('#')
      if row[0] == 'HOST'
        # HOST,name,url
        next if row.count < 3
        @bottle_hosts[row[1]] = row[2]
      elsif row.count >= 3
        # host,filename,hash
        @bottles_available.push BottleInfo.new(row[0],row[1],row[2])
      end
    end
    #puts @bottles_available
  end

  def load_platform_formulas_csv(filepath, types)
    CSV.foreach(filepath,"r") do |row|
      next if row.count <= 1
      next if row[0].start_with?('#')
      pkgtype = row[0]
      pkgname = row[1]

      next unless types.include?(pkgtype)
      @used_formulas.push pkgname
    end
    #puts @used_formulas
  end

  def download_bottle(destdir,info)
    url = @bottle_hosts[info.host]
    url += "/#{info.filename}"

    puts "Downloading '#{url}'"

    begin
      f = open(File.join(destdir, info.filename),"wb")
      response = Net::HTTP.get_response(URI.parse(url))
      if response.nil? || response.body.nil?
        puts "download failed"
        return false
      end
      f.write(response.body)
      f.close
    rescue
      puts "download exception"
      return false
    ensure
      f.close
    end

    return true
  end

  def is_cached(info, distros, destdir)
    distros.each do |distro|
      filename = make_bottle_filename(info,distro)
      path = File.join(destdir,filename)
      if File.exists?(path)
        if File.size(path) == 0
          File.unlink(path)
        else
          puts "'#{filename}' is cached"
          return true
        end
      end
    end
    false
  end

  def bottle_avail(filename)
    @bottles_available.each do |info|
      return info if info.filename == filename
    end
    false
  end

  def find_formula(name)
    @formulas.each do |info|
      return info if info.name == name
    end
    nil
  end

  def download_bottles(destdir, distros)
    puts "platform formulas:#{@used_formulas.join(',')}"
    missing = []
    @used_formulas.each do |name|
      info = find_formula name
      if info.nil?
        puts "ERROR: formula file not found for '#{name}'"
        next
      end

      next if is_cached(info,distros,destdir)

      is_cached = false
      distros.each do |distro|
        filename = make_bottle_filename(info,distro)
        puts "B:#{filename}"
        bi = bottle_avail(filename)
        if bi
          if download_bottle(destdir, bi)
            is_cached = true
            break
          end
        end
      end

      unless is_cached
        puts "bottle not found for #{info.to_s}"
        missing.push info
      end
    end
    return missing
  end

  def load_s3_file_list url
    return unless url.include?('s3')
    url = url.gsub(/\/bottles.*/,'')
    response = Net::HTTP.get_response(URI.parse(url))
    return if response.nil? || response.body.nil?
    response.body.split(/<[\/]?Key>/).each do |part|
      next unless part.index(/[<>]/).nil?
      next if part.index(/bottle.*\.tar/).nil?
      @s3files.push File.basename(part)
    end
  end
end

def get_distros(platform)
  if platform == 'darwin'
    return ['sierra','high_sierra','mojave']
  else
    return ['x86_64_linux']
  end
end

brewdir = "/usr/local/edarr"
formula_srcdir = "./provision/formula"
`mkdir -p ./build`
platform=`python3 ./get_platform.py --platform`.chomp.strip

puts "platform:#{platform}"

# load source formulas

obj = Wrangler.new

obj.load_source_formulas(formula_srcdir)

#obj.load_s3_file_list "https://osquery-packages.s3.amazonaws.com/bottles"
#obj.dump_bottle_csv
#puts obj.s3files.inspect
#exit 3

obj.load_bottles_csv("./provision/hosted-bottle-list.csv")
obj.load_platform_formulas_csv("./provision/#{platform}-formulas.csv", ['tool','dep'])

builds_needed = obj.download_bottles('./build', get_distros(platform))
builds_needed.each do |info|
  puts "Building bottle #{info.name}"
#  `#{brewdir}/bin/brew bottle --skip-relocation #{info.name}`
end
