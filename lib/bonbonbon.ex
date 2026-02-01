defmodule Bonbonbon do
  @moduledoc """
  Generates funny fantasy receipts using a fixed list of kid-room objects.

  - Always prints a fixed 24-char-wide header template first.
  - Then generates the rest of the receipt line-by-line using random objects from a static list.
  - Each generated line is assembled locally as: "<word> <amount>" and padded/truncated to 24 chars.
  """

  # 24 chars per line printer.
  @line_width 24

  # Fixed header template (must be printed first on every receipt).
  # We will pad each line to exactly 24 chars.
  @header_template [
    ".-=-=-=-=-=--=-=-=-=-=-.",
    "|   JONAS  BONFABRIK   |",
    "|  * Bons * BonBons *  |",
    "'-=-=-=-=-=--=-=-=-=-=-'"
  ]

  @doc """
  Build a receipt string from a list of entered numbers.

  The receipt is 24 characters wide.
  The receipt begins with the fixed header template.

  Each item line is built locally as: "<word> <amount>".
  """
  def generate_receipt(numbers, opts \\ []) when is_list(numbers) do
    header_lines = Enum.map(@header_template, &fit_line/1)

    {item_lines, _used_words} =
      Enum.reduce(numbers, {[], []}, fn num, {acc_lines, used_words} ->
        amount = Integer.to_string(num)
        max_word_len = max_word_len_for_right_amount(amount)
        word = random_object(max_word_len)
        # word left, amount right
        spaces = @line_width - String.length(word) - String.length(amount)
        spaces = if spaces < 1, do: 1, else: spaces
        line = fit_line(word <> String.duplicate(" ", spaces) <> amount)
        {[line | acc_lines], [word | used_words]}
      end)

    items = Enum.reverse(item_lines)

    total = Enum.sum(numbers)

    footer =
      [
        fit_line("------------------------"),
        fit_line(sum_line(total))
      ]

    (header_lines ++ [fit_line("")] ++ items ++ [fit_line("")] ++ footer)
    |> Enum.join("\n")
  end

  # --- Helpers ---
  defp random_object(max_len) when is_integer(max_len) and max_len >= 1 do
    Bonbonbon.Objects.list()
    |> Enum.filter(&(String.length(&1) <= max_len))
    |> case do
      [] -> "Spielzeug" |> String.slice(0, max_len)
      list -> Enum.random(list)
    end
  end

  defp sum_line(total) when is_integer(total) do
    amount = Integer.to_string(total)
    label = "SUMME"
    spaces = @line_width - String.length(label) - String.length(amount)
    spaces = if spaces < 1, do: 1, else: spaces
    label <> String.duplicate(" ", spaces) <> amount
  end

  defp max_word_len_for_right_amount(amount) when is_binary(amount) do
    # One space between word and amount
    max(@line_width - String.length(amount) - 1, 1)
  end

  defp fit_line(line) when is_binary(line) do
    line
    |> String.replace("\r", "")
    |> String.slice(0, @line_width)
    |> pad_right(@line_width)
  end

  defp pad_right(s, width) do
    len = String.length(s)

    if len >= width do
      s
    else
      s <> String.duplicate(" ", width - len)
    end
  end

  # --- Simple CLI ---

  defmodule CLI do
    @moduledoc false

    def main do
      IO.puts("Gib pro Zeile eine Zahl (max 5 Zeichen). Leer = Kassenzettel fertig + Summe.")
      numbers = read_numbers([])

      receipt = Bonbonbon.generate_receipt(numbers)
      IO.puts("\n" <> receipt <> "\n\n\n\n\n\n")
    end

    defp read_numbers(acc) do
      input =
        IO.gets("Zahl: ")
        |> to_string()
        |> String.trim()

      cond do
        input == "" ->
          Enum.reverse(acc)

        String.length(input) > 5 ->
          IO.puts("Bitte max 5 Zeichen.")
          read_numbers(acc)

        not String.match?(input, ~r/^\d+$/) ->
          IO.puts("Bitte nur Ziffern (0-9).")
          read_numbers(acc)

        true ->
          num = String.to_integer(input)
          read_numbers([num | acc])
      end
    end
  end

end


defmodule KeypadPrinter do
  @moduledoc """
  Reads digits from either:

  1) A Linux evdev keyboard device (/dev/input/event*) when `KBD_DEV` is set, OR
  2) STDIN (works on macOS) when `KBD_DEV` is not set.

  Behavior:
  - Digits are collected into a buffer; if more than 5 digits are typed, only the first 5 are kept.
  - When '+' is pressed, the current buffered number is committed and the next number can be entered.
  - When Enter is pressed, the buffered number (if any) is committed, the receipt is generated, and printed.

  Printer:
  - If `PRINTER_DEV` is set (e.g. /dev/usb/lp0), output is written there.
  - Otherwise it prints to STDOUT (useful for testing on macOS).

  Usage (Raspberry Pi / evdev):
    export KBD_DEV="/dev/input/by-id/usb-...-event-kbd"
    export PRINTER_DEV="/dev/usb/lp0"
    mix run --no-halt

  Usage (macOS test mode):
    mix run -e "KeypadPrinter.CLI.main()"
  """

  use GenServer

  @type_key 0x01

  # Normal Enter (KEY_ENTER) and Keypad Enter (KEY_KPENTER)
  @enter_codes MapSet.new([28, 96])

  # Keypad Plus is usually KEY_KPPLUS = 78
  @plus_codes MapSet.new([78])

  # Numpad digits mapping (common Linux evdev codes)
  @kp_map %{
    82 => "0",
    79 => "1",
    80 => "2",
    81 => "3",
    75 => "4",
    76 => "5",
    77 => "6",
    71 => "7",
    72 => "8",
    73 => "9"
  }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    mode = Keyword.get(opts, :mode, :evdev)
    printer = Keyword.get(opts, :printer)

    {pfd, printer_label} = open_printer(printer)

    state = %{
      mode: mode,
      kfd: nil,
      pfd: pfd,
      printer_label: printer_label,
      buf: "",
      numbers: []
    }

    case mode do
      :evdev ->
        kbd = Keyword.fetch!(opts, :kbd)

        kfd =
          case File.open(kbd, [:read, :binary, :raw]) do
            {:ok, fd} -> fd
            {:error, reason} -> raise "Cannot open keyboard device #{kbd}: #{inspect(reason)}"
          end

        IO.puts("[keypad_printer] evdev input from #{kbd}")
        IO.puts("[keypad_printer] output to #{printer_label}")
        IO.puts("[keypad_printer] digits -> buffer, '+' commits, Enter prints")
        IO.puts("[keypad_printer] READY (booted) ✅")
        IO.puts("[keypad_printer] debug: printing key events (type/code/value)")

        send(self(), :read)
        {:ok, %{state | kfd: kfd}}

      :stdin ->
        IO.puts("[keypad_printer] stdin mode")
        IO.puts("[keypad_printer] output to #{printer_label}")
        IO.puts("[keypad_printer] type digits, then '+' to commit, Enter to print")

        send(self(), :stdin_loop)
        {:ok, state}
    end
  end

  # --------------------
  # EVDEV MODE
  # --------------------

  @impl true
  def handle_info(:read, state = %{mode: :evdev}) do
    case read_event(state.kfd) do
      {:ok, {type, code, value}} ->
        IO.puts("[keypad_printer] event type=#{type} code=#{code} value=#{value}")
        state = handle_key(type, code, value, state)
        send(self(), :read)
        {:noreply, state}

      :eof ->
        Process.send_after(self(), :read, 50)
        {:noreply, state}

      {:error, :eintr} ->
        send(self(), :read)
        {:noreply, state}

      {:error, reason} ->
        IO.puts("[keypad_printer] read error: #{inspect(reason)}")
        Process.send_after(self(), :read, 200)
        {:noreply, state}
    end
  end

  # --------------------
  # STDIN MODE (macOS)
  # --------------------

  @impl true
  def handle_info(:stdin_loop, state = %{mode: :stdin}) do
    # Simple prompt loop that works everywhere:
    # - user types digits (or digits+"+") and presses Enter
    # - empty line triggers printing
    input =
      IO.gets("Eingabe (digits, digits+, oder leer=print): ")
      |> to_string()
      |> String.trim()

    cond do
      input == "" ->
        state = print_and_reset(state)
        send(self(), :stdin_loop)
        {:noreply, state}

      String.ends_with?(input, "+") ->
        digits = String.trim_trailing(input, "+")
        state = commit_digits(digits, state)
        send(self(), :stdin_loop)
        {:noreply, state}

      true ->
        # Treat as digits (no commit yet) – user can type another line with '+' or empty to print.
        state = buffer_digits(input, state)
        send(self(), :stdin_loop)
        {:noreply, state}
    end
  end

  # key press value: 1 = press, 0 = release, 2 = repeat
  defp handle_key(@type_key, code, 1, state) do
    cond do
      MapSet.member?(@enter_codes, code) ->
        IO.puts("[keypad_printer] ENTER (code=#{code})")
        # Enter prints: commit current buffer (if any), then print receipt.
        state
        |> commit_buffer_if_any()
        |> print_and_reset()

      MapSet.member?(@plus_codes, code) ->
        IO.puts("[keypad_printer] PLUS (code=#{code})")
        # '+' commits the current buffered number and starts a new one.
        commit_buffer_if_any(state)

      digit = @kp_map[code] ->
        IO.puts("[keypad_printer] digit #{digit} (code=#{code})")
        buffer_digits(digit, state)

      true ->
        state
    end
  end

  defp handle_key(_type, _code, _value, state), do: state

  # Keep only first 5 digits in the buffer.
  defp buffer_digits(digits, state) when is_binary(digits) do
    digits = String.replace(digits, ~r/\D+/, "")

    if digits == "" do
      state
    else
      new_buf = (state.buf <> digits) |> String.slice(0, 5)
      %{state | buf: new_buf}
    end
  end

  defp commit_buffer_if_any(state) do
    if state.buf == "" do
      state
    else
      num = String.to_integer(state.buf)
      IO.puts("[keypad_printer] committed #{num}")
      %{state | numbers: [num | state.numbers], buf: ""}
    end
  end

  defp commit_digits(digits, state) do
    state
    |> buffer_digits(digits)
    |> commit_buffer_if_any()
  end

  defp print_and_reset(state) do
    numbers = Enum.reverse(state.numbers)

    if numbers == [] do
      IO.puts("[keypad_printer] nothing to print")
      %{state | numbers: [], buf: ""}
    else
      receipt = Bonbonbon.generate_receipt(numbers)
      print_receipt(state.pfd, receipt)
      IO.puts("[keypad_printer] printed #{length(numbers)} lines, total=#{Enum.sum(numbers)}")
      %{state | numbers: [], buf: ""}
    end
  end

  defp print_receipt(:stdout, receipt) do
    IO.puts("\n" <> receipt <> "\n\n\n\n\n\n")
  end

  defp print_receipt(pfd, receipt) do
    IO.binwrite(pfd, "\n" <> receipt <> "\n\n\n\n\n\n")
  end

  defp open_printer(nil) do
    # Default for dev on macOS: just print to stdout
    {:stdout, "STDOUT"}
  end

  defp open_printer(printer_path) when is_binary(printer_path) do
    case File.open(printer_path, [:write, :binary, :raw]) do
      {:ok, fd} -> {fd, printer_path}
      {:error, reason} -> raise "Cannot open printer device #{printer_path}: #{inspect(reason)}"
    end
  end

  # Linux struct input_event on 64-bit userspace:
  # 8 + 8 + 2 + 2 + 4 = 24 bytes
  defp read_event(fd) do
    case :file.read(fd, 24) do
      {:ok,
       <<_sec::signed-little-64, _usec::signed-little-64, type::unsigned-little-16,
         code::unsigned-little-16, value::signed-little-32>>} ->
        {:ok, {type, code, value}}

      :eof ->
        :eof

      {:error, reason} ->
        {:error, reason}
    end
  end

  defmodule CLI do
    @moduledoc false

    def main do
      kbd = System.get_env("KBD_DEV")
      printer = System.get_env("PRINTER_DEV")

      cond do
        is_binary(kbd) and kbd != "" ->
          {:ok, _pid} = KeypadPrinter.start_link(mode: :evdev, kbd: kbd, printer: printer)
          Process.sleep(:infinity)

        true ->
          {:ok, _pid} = KeypadPrinter.start_link(mode: :stdin, printer: printer)
          Process.sleep(:infinity)
      end
    end
  end
end
