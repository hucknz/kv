require "file_utils"

# HID Keyboard Module for USB Gadget functionality
module HIDKeyboard
  Log = ::Log.for(self)

  # Key modifier mappings
  KMOD = {
    "ctrl"        => 0x01_u8,
    "left-ctrl"   => 0x01_u8,
    "right-ctrl"  => 0x10_u8,
    "shift"       => 0x02_u8,
    "left-shift"  => 0x02_u8,
    "right-shift" => 0x20_u8,
    "alt"         => 0x04_u8,
    "left-alt"    => 0x04_u8,
    "right-alt"   => 0x40_u8,
    "meta"        => 0x08_u8,
    "left-meta"   => 0x08_u8,
    "right-meta"  => 0x80_u8,
  }

  # Special key value mappings
  KVAL = {
    "1" => 0x1e_u8, "2" => 0x1f_u8, "3" => 0x20_u8, "4" => 0x21_u8, "5" => 0x22_u8,
    "6" => 0x23_u8, "7" => 0x24_u8, "8" => 0x25_u8, "9" => 0x26_u8, "0" => 0x27_u8,
    "-" => 0x2d_u8, "=" => 0x2e_u8, "[" => 0x2f_u8, "]" => 0x30_u8, "\\" => 0x31_u8,
    ";" => 0x33_u8, "'" => 0x34_u8, "`" => 0x35_u8, "," => 0x36_u8, "." => 0x37_u8, "/" => 0x38_u8,
    "enter" => 0x28_u8, "return" => 0x28_u8, "esc" => 0x29_u8, "escape" => 0x29_u8,
    "backspace" => 0x2a_u8, "tab" => 0x2b_u8, "space" => 0x2c_u8, "spacebar" => 0x2c_u8,
    "caps-lock" => 0x39_u8, "f1" => 0x3a_u8, "f2" => 0x3b_u8, "f3" => 0x3c_u8, "f4" => 0x3d_u8,
    "f5" => 0x3e_u8, "f6" => 0x3f_u8, "f7" => 0x40_u8, "f8" => 0x41_u8, "f9" => 0x42_u8,
    "f10" => 0x43_u8, "f11" => 0x44_u8, "f12" => 0x45_u8, "insert" => 0x49_u8, "home" => 0x4a_u8,
    "pageup" => 0x4b_u8, "delete" => 0x4c_u8, "del" => 0x4c_u8, "end" => 0x4d_u8,
    "pagedown" => 0x4e_u8, "right" => 0x4f_u8, "left" => 0x50_u8, "down" => 0x51_u8, "up" => 0x52_u8,
    "num-lock" => 0x53_u8, "kp-slash" => 0x54_u8, "kp-asterisk" => 0x55_u8, "kp-minus" => 0x56_u8,
    "kp-plus" => 0x57_u8, "kp-enter" => 0x58_u8,
  }

  # Create an 8-byte keyboard report from keys/modifiers
  def self.create_keyboard_report(keys : Array(String), modifiers : Array(String) = [] of String) : Bytes
    report = Bytes.new(8, 0_u8)
    key_index = 0

    # Apply modifiers first
    modifiers.each do |mod|
      if mod_val = KMOD[mod.downcase]?
        report[0] |= mod_val
      end
    end

    # Apply keys (max 6 simultaneous keys)
    keys.each do |key|
      break if key_index >= 6

      if val = KVAL[key]?
        shifted_chars = ["!", "@", "#", "$", "%", "^", "&", "*", "(", ")", "_", "+", "{", "}", "|", ":", "\"", "~", "<", ">", "?"]
        if shifted_chars.includes?(key)
          report[0] |= KMOD["shift"]
        end
        report[2 + key_index] = val
        key_index += 1
      elsif key.size == 1
        char = key[0]
        if char >= 'a' && char <= 'z'
          report[2 + key_index] = (char.ord - 'a'.ord + 0x04).to_u8
          key_index += 1
        elsif char >= 'A' && char <= 'Z'
          report[0] |= KMOD["shift"]
          report[2 + key_index] = (char.downcase.ord - 'a'.ord + 0x04).to_u8
          key_index += 1
        elsif char >= '0' && char <= '9'
          if val = KVAL[char.to_s]?
            report[2 + key_index] = val
            key_index += 1
          end
        else
          if val = KVAL[char.to_s]?
            shifted_chars = ["!", "@", "#", "$", "%", "^", "&", "*", "(", ")", "_", "+", "{", "}", "|", ":", "\"", "~", "<", ">", "?"]
            if shifted_chars.includes?(char.to_s)
              report[0] |= KMOD["shift"]
            end
            report[2 + key_index] = val
            key_index += 1
          end
        end
      end
    end

    report
  end

  # Robust write that blocks until 'buf' is fully written (handles EINTR/EAGAIN)
  private def self.write_all(fd : Int32, buf : Bytes) : Bool
    total = 0
    base = buf.to_unsafe
    len = buf.size

    while total < len
      rc = LibC.write(fd, (base + total).as(Pointer(Void)), (len - total).to_size_t)
      if rc < 0
        errno_val = Errno.value
        if errno_val == Errno::EINTR || errno_val == Errno::EAGAIN || errno_val == Errno::EWOULDBLOCK
          sleep 0.005 # back off 5ms and retry
          next
        else
          Log.error { "write_all failed with errno: #{errno_val}" }
          return false
        end
      else
        total += rc
      end
    end
    true
  end

  # Send a press report, then an empty release report, using blocking I/O
  def self.send_keyboard_report(device_path : String, report : Bytes)
    fd = LibC.open(device_path, LibC::O_RDWR, 0o666)
    if fd < 0
      raise "Failed to open HID device #{device_path}"
    end

    begin
      Log.debug { "Writing key press: #{report.map { |b| "%02x" % b }.join(" ")}" }
      unless write_all(fd, report)
        Log.error { "Key press write failed" }
        return
      end

      # Give the host time to process the press as a distinct report
      sleep 0.007.seconds

      empty_report = Bytes.new(8, 0_u8)
      Log.debug { "Writing key release: #{empty_report.map { |b| "%02x" % b }.join(" ")}" }
      unless write_all(fd, empty_report)
        Log.error { "Key release write failed" }
        return
      end

      Log.debug { "HID write completed successfully" }
    ensure
      LibC.close(fd)
    end
  end

  # Convenience to force "all keys up" on the device
  def self.all_keys_up(device_path : String)
    fd = LibC.open(device_path, LibC::O_RDWR, 0o666)
    if fd < 0
      Log.error { "Failed to open HID device for all_keys_up: #{device_path}" }
      return
    end
    begin
      empty_report = Bytes.new(8, 0_u8)
      write_all(fd, empty_report)
    ensure
      LibC.close(fd)
    end
  end

  # Type text: per char press+release with realistic delays and blocking writes
  def self.send_text(device_path : String, text : String)
    fd = LibC.open(device_path, LibC::O_RDWR, 0o666)
    if fd < 0
      Log.error { "Failed to open HID device for send_text: #{device_path}" }
      return
    end

    begin
      text.each_char do |char|
        # Build a single-key report for this char
        report = Bytes.new(8, 0_u8)
        char_str = char.to_s

        if char == ' '
          report[2] = KVAL["space"]
        elsif char >= 'a' && char <= 'z'
          report[2] = (char.ord - 'a'.ord + 0x04).to_u8
        elsif char >= 'A' && char <= 'Z'
          report[0] = KMOD["shift"]
          report[2] = (char.downcase.ord - 'a'.ord + 0x04).to_u8
        elsif val = KVAL[char_str]?
          shifted_chars = ["!", "@", "#", "$", "%", "^", "&", "*", "(", ")", "_", "+", "{", "}", "|", ":", "\"", "~", "<", ">", "?"]
          report[0] = KMOD["shift"] if shifted_chars.includes?(char_str)
          report[2] = val
        else
          Log.debug { "Skipping unsupported character: '#{char}' (#{char.ord})" }
          next
        end

        Log.debug { "Text char '#{char}' press: #{report.map { |b| "%02x" % b }.join(" ")}" }
        unless write_all(fd, report)
          Log.error { "Text press write failed for '#{char}'" }
          next
        end

        sleep 0.007.seconds

        empty_report = Bytes.new(8, 0_u8)
        Log.debug { "Text char '#{char}' release: #{empty_report.map { |b| "%02x" % b }.join(" ")}" }
        unless write_all(fd, empty_report)
          Log.error { "Text release write failed for '#{char}'" }
          next
        end

        # Small gap between characters so hosts don't coalesce
        sleep 0.003.seconds
      end

      # Extra safety: ensure keyboard is in a released state at the end
      empty_report = Bytes.new(8, 0_u8)
      write_all(fd, empty_report)
    ensure
      LibC.close(fd)
    end
  end
end
