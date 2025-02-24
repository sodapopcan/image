defmodule Image do
  @moduledoc """
  `Image` is based upon the fabulous
  [vix](https://hex.pm/packages/vix) library that provides a [libvips](https://www.libvips.org)
  wrapper for Elixir.

  `Image` is intended to provide well-documented common image processing functions in
  an idiomatic Elixir functional style as a layer above the very comprehensive set
  of functions in `Vix` and `libvips`.

  In a very simple image resizing
  [benchmark](https://github.com/kipcole9/image/blob/main/bench/image_resize.exs),
  `Image` is approximately 2 to 3 times faster than `Mogrify` and uses about 5 times
  less memory.

  """

  alias Vix.Vips.{Operation, MutableImage}
  alias Vix.Vips.Image, as: Vimage

  alias Image.{Exif, Xmp, Complex, Options, Color, Interpretation, BlendMode, BandFormat}
  alias Image.Options.{Resize, Thumbnail, Compose, Open, ChromaKey}
  alias Image.Math
  alias Image.Draw

  import Image.Color, only: :macros

  @typedoc """
  THe structure of an image returned from `Kino.Input.read/1`
  when the input field is a `Kino.Input.image/1` type.
  """
  @type kino_image :: %{data: binary(), width: pos_integer(), height: pos_integer(), format: :rgb}

  @typedoc """
  A 512 bit binary hash of an image.

  Useful for comparing the similarity of
  two images. See `Image.dhash/1` and
  `Image.hamming_distance/2`.
  """
  @type image_hash :: binary()

  @typedoc """
  The valid sources of image data when opening an
  image.
  """
  @type image_data :: Path.t() | File.Stream.t() | binary()

  @typedoc """
  Represents either in image, or a color
  that is used to fill a new image
  """
  @type image_or_color :: Vimage.t() | Color.t()

  @typedoc """
  The valid rendering intent values. For all
  functions that take an optional intent
  parameter the default is `:perceptual`.

  ## Perceptual Intent

  Perceptual rendering is used to process photographic
  type images. This intent processes the colors so that
  the output reproduction is pleasing. This process
  tends to change the color from the original, so no
  guarantee the reproduction will be accurate against
  the original.

  ## Relative Intent

  Relative colorimetric changes all the colours out
  of gamut to the nearest colour in gamut, so many
  colours change to the same one. It DOES NOT change
  colours in gamut. Perceptual changes ALL the colours
  in the image in a proportional way so that they lie
  in the output device gamut.

  ## Saturation Intent

  Saturation moves in-gamut colors toward the edge of the
  destination gamut for maximum saturation and impact.
  This intent will make an image more colorful by using
  the full gamut of the destination device. This intent
  cares not for the genuine representation of color.

  ## Absolute Intent

  Absolute rendering attempts to reproduce all
  colors numerically (destination = source). This
  can cause unexpected results if the source gamut is
  larger than the destination.

  """
  @type render_intent :: :perceptual | :relative | :saturation | :absolute

  @typedoc """
  Error messages returned by `libvips`

  Typically a string.

  """
  @type error_message :: term()

  @typedoc """
  A pixel is represented as a list of number values or
  a single number (which is then assumed to be the value
  for all bands).

  The number of list elements is determined by
  the colorspace interpretations. For example:

  * `RGB` colorspace would be represented by
    a list of three floats like `[0.0, 0,0, 0.0]` for black.

  * `CMYK` colorspace would be represented by a
    list of four floats.

  * A `PNG` image can be in any appropriate
    colorspace but may also have an `alpha` band
    and therefore have three, four or five floats
    in a list to represent the pixel.

  """
  @type pixel :: [number()] | number()

  @typedoc """
  Image orientation.

  """
  @type aspect :: :landscape | :portrait | :square

  @typedoc """
  The level of transparency for an alpha band
  where `0` means fully opaque and `255` means
  fully transparent.

  """
  @type transparency :: 0..255 | :opaque | :transparent

  @typedoc """
  An image bounding box being a four element list
  of 2-tuples representing the points of a rectangle
  in the order top left -> top right -> bottom right ->
  bottom left.

  """
  @type quadrilateral :: [{x :: non_neg_integer(), y :: non_neg_integer()}, ...]

  @typedoc """
  The data type of the image, using the same
  type definitions as `t:Nx.Type.t/0`.
  """
  @type format :: {:u | :s | :f | :c | :bf, 8 | 16 | 32 | 64 | 128}

  @typedoc """
  The x location on an image which is either a
  non_negative 0-based integer relative to the image left or
  a negative -1-based integer relative to the image right or
  the symbolic references `:left`, `:center` and
  `:right`.

  """
  @type x_location :: integer() | :left | :center | :right

  @typedoc """
  The y location on an image which is either a
  non_negative 0-based integer relative to the image top or
  a negative -1-based integer relative to the image right or
  the symbolic references `:top`, `:middle` and
  `:bottom`.

  """
  @type y_location :: integer() | :top | :middle | :bottom

  @typedoc """
  A list of images or images with placement options used in
  Image.compose/2.

  """
  @type composition_list :: [composition, ...]

  @typedoc """
  A composition can be a simple image, or an image with
  associated composition options.

  """
  @type composition :: Vimage.t() | {Vimage.t(), Options.Compose.t()}

  # Default radius of rounded corners
  @default_round_corner_radius 50

  # Default squircle radius
  @default_squircle_radius 20

  # When pixelating an image resize to this scale
  # the scale up by the inverse using nearest_neighbour
  # scaling
  @pixelate_scale 0.05

  # The default sigma applied to a gaussian blur.
  # Used by blur/3 and feather/2
  @default_blur_sigma Options.Blur.default_blur_sigma()

  # if the ratio between width and height differs
  # by less than this amount, consider the image
  # to be square
  @square_when_ratio_less_than 0.0

  # The percent from absolute black and
  # absolute white in equalize/2 for
  # :each band option.
  @level_trim_percent 0.3

  # The default window applied to Operation.rank/3
  # when used in Image.reduce_noise/2
  @default_median_window_size 3

  # The percent from range of the tone
  # curve when equalizing luminance.
  @min_luminance 1.0
  @max_luminance 99.0

  # Representing an opque alpha band
  @opaque_ 0

  # Representing a transparent alpha band
  @transparent 255

  @doc """
  Guards whether the given struct is an image type
  either `Vix.Vips.Image` or `Vix.Vips.MutableImage`.
  """
  defguard is_image(image_type) when image_type in [Vimage, MutableImage]

  @doc """
  Guards whether the coordinates can be reasonably
  interpreted as a bounding box.

  `left` and `top` when positive are relative to
  the left and top of the image respectively. When
  negative they are relative to the right and bottom
  of the image.

  """
  @doc subject: "Guard"
  defguard is_box(left, top, width, height)
           when is_integer(left) and is_integer(top) and is_integer(width) and is_integer(height) and
                  width > 0 and height > 0

  @doc """
  Guards whether a parameter is a rectangular bounding box. A
  rectangular bounding box is a list of four 2-tuples that must
  represent a rectangle (not an arbitrary quadrilateral),

  The order of points is top_left -> top right -> bottom
  right -> bottm left.

  """
  @doc subject: "Guard"
  defguard is_rectangle(top_left, top_right, bottom_right, bottom_left)
           when is_tuple(top_left) and
                  is_tuple(top_right) and
                  is_tuple(bottom_right) and
                  is_tuple(bottom_left) and
                  elem(top_left, 0) == elem(bottom_left, 0) and
                  elem(top_right, 0) == elem(bottom_right, 0) and
                  elem(top_left, 1) == elem(top_right, 1) and
                  elem(bottom_right, 1) == elem(bottom_left, 1)

  @doc """
  Guards whether a number can be reasonably interpreted
  as a size (as in size of a crop or mask)

  """
  @doc subject: "Guard"
  defguard is_size(size) when is_integer(size) and size > 0

  @doc """
  Guards whether a term might be reasonably interpreted
  as an image pixel.

  """
  @doc subject: "Guard"
  defguard is_pixel(value) when is_number(value) or is_list(value)

  @doc """
  Guards whether a value is a percentage as representeed
  by a float between `-1.0` and `1.0`.
  """
  @doc subject: "Guard"
  defguard is_percent(value) when is_float(value) and value >= -1.0 and value <= 1.0

  @doc """
  Guards whether a value is a positive percentage as representeed
  by a float greater than `0.0` and less than or equal to `1.0`.
  """
  @doc subject: "Guard"
  defguard is_positive_percent(value) when is_float(value) and value >= 0.0 and value <= 1.0

  @doc """
  Guards whether a value is a multiplier as representeed
  by a float greater than `0.0`.
  """
  @doc subject: "Guard"
  defguard is_multiplier(value) when is_float(value) and value >= 0.0

  @doc """
  Create a new image of the given dimensions.

  ### Arguments

  Either `width` and `height` OR `image` should be
  provided.

  * `width` is the image width as an integer.

  * `height` is the image height as an integer.

  * `image` is an image from which the `width`, `height` are
    derived.

  * `options` is a keyword list of options.

  ### Options

  * `:color` defines the color of the image. This
    can be specified as a single integer which will
    be applied to all bands, or a list of
    integers representing the color for each
    band. The default is `0`, meaning black. The color
    can also be supplied as a CSS color name as a
    string or atom. For example: `:misty_rose`. See
    `Image.Color.color_map/0` and `Image.Color.rgb_color/1`.

  * `:bands` defines the number of bands (channels)
    to be created. The default is the number of bands of
    `:color` option or if `:color` is an integer then the
    default value is `3`.

  * `:format` defines the format of the image. The
    default is `{:u, 8}`.

  * `:interpretation` defines the interpretation of
    the image. The default is `:srgb`.

  ### Returns

  * `{:ok, image}` or

  * `{:error, reason}`

  ### Notes

  * Either `width` and `height` OR `image` should
    be provided as arguments but NOT both.

  ### Examples

        # 100x100 pixel image of dark blue slate color
        iex> {:ok, _image} = Image.new(100, 100, color: :dark_slate_blue)

        # 100x100 pixel green image, fully transparent
        iex> {:ok, _image} = Image.new(100, 100, color: [0, 255, 0, 255], bands: 4)

  """
  @doc subject: "Load and save"

  @spec new(width :: pos_integer(), height :: pos_integer()) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def new(width, height)
      when is_integer(width) and is_integer(height) and width > 0 and height > 0 do
    new(width, height, [])
  end

  @spec new(image :: %Vimage{}, options :: Options.New.t()) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def new(%Vimage{} = image, options) do
    {width, height, bands} = Image.shape(image)
    options = Keyword.put_new(options, :bands, bands)

    new(width, height, options)
  end

  @doc subject: "Load and save"

  @spec new(width :: pos_integer(), height :: pos_integer(), options :: Options.New.t()) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def new(width, height, options)
      when is_integer(width) and is_integer(height) and width > 0 and height > 0 do
    with {:ok, options} <- Options.New.validate_options(options) do
      {:ok, pixel} =
        Vix.Vips.Operation.black!(1, 1, bands: options.bands)
        |> Image.Math.add!(options.color)
        |> Operation.cast(options.format)

      {:ok, image} = Operation.embed(pixel, 0, 0, width, height, extend: :VIPS_EXTEND_COPY)

      Operation.copy(image,
        interpretation: options.interpretation,
        xres: options.x_res,
        yres: options.y_res,
        xoffset: options.x_offset,
        yoffset: options.y_offset
      )
    end
  end

  @doc """
  Return a new image of the given dimensions and
  background color or raise an exception.

  ### Arguments

  Either `width` and `height` OR `image` should be
  provided.

  * `width` is the image width as an integer.

  * `height` is the image height as an integer.

  * `image` is an image from which the `width`, `height` re
    derived.

  * `options` is a keyword list of options.

  ### Options

  * `:bands` defines the number of bands (channels)
    to be created. The default is `3`.

  * `:color` defines the color of the image. This
    can be specified as a single integer which will
    be applied to all bands, or a list of
    integers representing the color for each
    band. The default is `0`, meaning black. The color
    can also be supplied as a CSS color name as a
    string or atom. For example: `:misty_rose`. See
    `Image.Color.color_map/0` and `Image.Color.rgb_color/1`.

  * `:format` defines the format of the image. The
    default is `{:u, 8}`.

  * `:interpretation` defines the interpretation of
    the image. The default is `:srgb`.

  ### Returns

  * `{:ok, image}` or

  * `{:error, reason}`

  ### Notes

  * Either `width` and `height` OR `image` should
    be provided as arguments but NOT both.

  ### Examples

        # 100x100 pixel image of dark blue slate color
        iex> {:ok, _image} = Image.new(100, 100, color: :dark_slate_blue)

        # 100x100 pixel green image, fully transparent
        iex> {:ok, _image} = Image.new(100, 100, color: [0, 255, 0, 1], bands: 4)

  """
  @doc subject: "Load and save"
  @spec new!(width :: pos_integer(), height :: pos_integer()) ::
          Vimage.t() | no_return()

  def new!(width, height)
      when is_integer(width) and is_integer(height) and width > 0 and height > 0 do
    case new(width, height) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @spec new!(image :: %Vimage{}, options :: Options.New.t()) ::
          Vimage.t() | no_return()

  def new!(%Vimage{} = image, options) do
    case new(image, options) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc subject: "Load and save"

  @spec new!(width :: pos_integer(), height :: pos_integer(), options :: Options.New.t()) ::
          Vimage.t() | no_return()

  def new!(width, height, options)
      when is_integer(width) and is_integer(height) and width > 0 and height > 0 do
    case new(width, height, options) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Create a new image of the same shape as the
  provided image.

  The function creates a new image with the same
  width, height and bands as the image argument.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0` from
    which the new images `width` and `height` and
  ` bands` will be derived.

  * `options` is a keyword list of options.

  ### Options

  * `:bands` defines the number of bands (channels)
    to be created. The default is the number of bands
    in `image`.

  * `:color` defines the color of the image. This
    can be specified as a single integer which will
    be applied to all bands, or a list of
    integers representing the color for each
    band. The default is `0`, meaning black. The color
    can also be supplied as a CSS color name as a
    string or atom. For example: `:misty_rose`. See
    `Image.Color.color_map/0` and `Image.Color.rgb_color/1`.

  * `:format` defines the format of the image. The
    default is `{:u, 8}`.

  * `:interpretation` defines the interpretation of
    the image. The default is `:srgb`.

  ### Returns

  * `{:ok, image}` or

  * `{:error, reason}`

  """
  @doc subject: "Load and save", since: "0.1.13"

  @spec new(image :: %Vimage{}) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def new(%Vimage{} = image) do
    new(image, [])
  end

  @doc """
  Return a new image of the same shape as the
  provided image or raise an exception.

  The function creates a new image with the same
  width, height and bands as the image argument.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0` from
    which the new images `width` and `height` and
  ` bands` will be derived.

  * `options` is a keyword list of options.

  ### Options

  * `:bands` defines the number of bands (channels)
    to be created. The default is the number of bands
    in `image`.

  * `:color` defines the color of the image. This
    can be specified as a single integer which will
    be applied to all bands, or a list of
    integers representing the color for each
    band. The default is `0`, meaning black. The color
    can also be supplied as a CSS color name as a
    string or atom. For example: `:misty_rose`. See
    `Image.Color.color_map/0` and `Image.Color.rgb_color/1`.

  * `:format` defines the format of the image. The
    default is `{:u, 8}`.

  * `:interpretation` defines the interpretation of
    the image. The default is `:srgb`.

  ### Returns

  * `{:ok, image}` or

  * `{:error, reason}`

  """
  @doc subject: "Load and save", since: "0.1.13"

  def new!(%Vimage{} = image) do
    case new(image, []) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Opens an image file or stream for image processing.

  ### Arguments

  * `image_path_or_stream_or_binary` is the file system path to an image
    file or a `t:File.Stream.t/0` or any `t:Enumerable.t/0`. It
    can also be any binary `.jpg`, `.png`, `.webp` or `.svg` image.

  * `options` is a keyword list of options. The default is
    `[access: :random]` for all images except images
    derived from binary image data.

  ### Options

  The available options depend upon the image type.

  #### All image types

  * `:access` is the file access mode, either `:random`
    or `:sequential`. The default is `:random`.
    When `:sequential`, `Image` (via `Vix`) is able
    to support streaming transformations and optimise
    memory usage more effectively. However `:sequential`
    also means that some operations cannot be completed
    because they would require non-sequential access to
    the image. In these cases, `:random` access is required.

  * `:fail_on` sets the error level at which image
    loading and decoding will stop. The default is `:none`.
    Each error state implies all the states before it such
    that `:error` implies also `:truncated`.

  #### JPEG image options

  * `:shrink` is an integer factor in the range `1..16` by
    which the image is reduced upon loading. This is an
    optimization that can result in improved performance and
    reduced memory usage if the image is being loaded
    with the intent to resize it to smaller dimensions. The
    default value is `1` meaning no shrink-on-load.

  * `:autorotate` is a boolean value indicating if
    the image should be rotated according to the orientation
    data stored in the image metadata. The default is
    `false`.

  #### WEBP options

  * `:scale` will scale the image on load. The value is
    a number greater than `0` and less than or equal
    to `1024` with a default of `1` meaning no scaling
    on load. Numbers less than `1.0` scale the image down
    so that a scale of `0.5` will halve the image size on
    load.

  * `:page` indicates the first page to be loaded. The
    value is in the range `0..100_000` with a default
    value of `0`. This parameter is useful on animated images.

  * `:pages` indicates the number of pages to load.
    The value must be between `-1` and `100_000`. The default
    value is `1`.  A value of `-1` would load all the available
    pages which is useful if you want to keep the animation of
    the input image. The atom `:all` can be used in place of
    `-1` to indicate all pages should be loaded.

  #### TIFF options

  * `:autorotate` is a boolean value indicating if
    the image should be rotated according to the orientation
    data stored in the image metadata. The default is
    `false`.

  * `:page` indicates the first page to be loaded. The
    value is in the range `0..100_000` with a default
    value of `0`. This parameter is useful on animated images.

  * `:pages` indicates the number of pages to load.
    The value must be between `-1` and `100_000`. The default
    value is `1`.  A value of `-1` would load all the available
    pages which is useful if you want to keep the animation of
    the input image. The atom `:all` can be used in place of
    `-1` to indicate all pages should be loaded.

  #### GIF options

  * `:page` indicates the first page to be loaded. The
    value is in the range `0..100_000` with a default
    value of `0`. This parameter is useful on animated images.

  * `:pages` indicates the number of pages to load.
    The value must be between `-1` and `100_000`. The default
    value is `1`.  A value of `-1` would load all the available
    pages which is useful if you want to keep the animation of
    the input image. The atom `:all` can be used in place of
    `-1` to indicate all pages should be loaded.

  #### PNG options

  * There are no PNG-specific image loading
    options.

  ### Returns

  * `{:ok, image}` or

  * `{:error, message}`

  """
  @doc subject: "Load and save"

  @spec open(path_or_stream_or_binary :: image_data(), options :: Open.image_open_options()) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def open(path_or_stream_or_binary, options \\ [])

  # JPEG signature
  def open(<<0xFF, 0xD8, 0xFF, _::binary>> = image, options) do
    from_binary(image, options)
  end

  # PNG signature
  png =
    quote do
      <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, _::size(32), "IHDR", _::binary>>
    end

  def open(unquote(png) = image, options) do
    from_binary(image, options)
  end

  # WEBP signature
  def open(<<"RIFF", _::size(32), "WEBP", _::binary>> = image, options) do
    from_binary(image, options)
  end

  # GIF87a signature
  def open(<<0x47, 0x49, 0x46, 0x38, 0x37, 0x61, _::binary>> = image, options) do
    from_binary(image, options)
  end

  # GIF89a signature
  def open(<<0x47, 0x49, 0x46, 0x38, 0x39, 0x61, _::binary>> = image, options) do
    from_binary(image, options)
  end

  # TIF little endian
  def open(<<0x49, 0x49, 0x2A, 0x00, _::binary>> = image, options) do
    from_binary(image, options)
  end

  # TIF big endian
  def open(<<0x4D, 0x4D, 0x00, 0x2A, _::binary>> = image, options) do
    from_binary(image, options)
  end

  # SVG starting with either svg or xml tag
  def open(<<"<svg ", _::binary>> = image, options) do
    from_binary(image, options)
  end

  def open(<<"<?xml ", _::binary>> = image, options) do
    from_binary(image, options)
  end

  # A file path
  def open(image_path, options) when is_binary(image_path) do
    with {:ok, options} <- Options.Open.validate_options(options) do
      image_path
      |> String.split("[", parts: 2)
      |> do_open(options)
    end
  end

  # A File stream
  def open(%File.Stream{line_or_bytes: bytes} = image_stream, options) when is_integer(bytes) do
    with {:ok, options} <- Options.Open.validate_options(options) do
      options = loader_options(options)
      Vix.Vips.Image.new_from_enum(image_stream, options)
    end
  end

  # Any other stream
  def open(%Stream{} = image_stream, options) do
    with {:ok, options} <- Options.Open.validate_options(options) do
      options = loader_options(options)
      Vix.Vips.Image.new_from_enum(image_stream, options)
    end
  end

  def open(%File.Stream{}, _options) do
    {:error,
     "File stream must be specify the number of bytes to read. " <>
       "It should be opened as File.stream!(path, options, bytes) where bytes " <>
       "is the number of bytes to read on each iteration."}
  end

  defp do_open([path], options) do
    if File.exists?(path) do
      options = build_option_string(options)
      Vimage.new_from_file(path <> options)
    else
      {:error, :enoent}
    end
  end

  defp do_open([path, open_options], options) do
    if File.exists?(path) do
      open_options = String.trim_trailing(open_options, "]")
      options = build_option_string(open_options, options)
      Vimage.new_from_file(path <> options)
    else
      {:error, :enoent}
    end
  end

  defp loader_options(options) do
    "[" <> Enum.map_join(options, ",", fn {k, v} -> "#{k}=#{v}" end) <> "]"
  end

  @doc """
  Opens an image file for image processing
  returning an image or raising an exception.

  ### Arguments

  * `image_path_or_stream_or_binary` is the file system path to an image
    file or a `t:File.Stream.t/0` or any `t:Enumerable.t/0`. It
    can also be any binary `.jpg`, `.png`, `.webp` or `.svg` image.

  * `options` is a keyword list of options. The default is
    `[access: :random]` for all images except images
    derived from binary image data.

  ### Options

  The available options depend upon the image type.

  #### All image types

  * `:access` is the file access mode, either `:random`
    or `:sequential`. The default is `:random`.
    When `:sequential`, `Image` (via `Vix`) is able
    to support streaming transformations and optimise
    memory usage more effectively. However `:sequential`
    also means that some operations cannot be completed
    because they would require non-sequential access to
    the image. In these cases, `:random` access is required.

  * `:fail_on` sets the error level at which image
    loading and decoding will stop. The default is `:none`.
    Each error state implies all the states before it such
    that `:error` implies also `:truncated`.

  #### JPEG image options

  * `:shrink` is an integer factor in the range `1..16` by
    which the image is reduced upon loading. This is an
    optimization that can result in improved performance and
    reduced memory usage if the image is being loaded
    with the intent to resize it to smaller dimensions. The
    default value is `1` meaning no shrink-on-load.

  * `:autorotate` is a boolean value indicating if
    the image should be rotated according to the orientation
    data stored in the image metadata. The default is
    `false`.

  #### WEBP options

  * `:scale` will scale the image on load. The value is
    a number greater than `0` and less than or equal
    to `1024` with a default of `1` meaning no scaling
    on load. Numbers less than `1.0` scale the image down
    so that a scale of `0.5` will halve the image size on
    load.

  * `:page` indicates the first page to be loaded. The
    value is in the range `0..100_000` with a default
    value of `0`. This parameter is useful on animated images.

  * `:pages` indicates the number of pages to load.
    The value must be between `-1` and `100_000`. The default
    value is `1`.  A value of `-1` would load all the available
    pages which is useful if you want to keep the animation of
    the input image. The atom `:all` can be used in place of
    `-1` to indicate all pages should be loaded.

  #### TIFF options

  * `:autorotate` is a boolean value indicating if
    the image should be rotated according to the orientation
    data stored in the image metadata. The default is
    `false`.

  * `:page` indicates the first page to be loaded. The
    value is in the range `0..100_000` with a default
    value of `0`. This parameter is useful on animated images.

  * `:pages` indicates the number of pages to load.
    The value must be between `-1` and `100_000`. The default
    value is `1`.  A value of `-1` would load all the available
    pages which is useful if you want to keep the animation of
    the input image. The atom `:all` can be used in place of
    `-1` to indicate all pages should be loaded.

  #### GIF options

  * `:page` indicates the first page to be loaded. The
    value is in the range `0..100_000` with a default
    value of `0`. This parameter is useful on animated images.

  * `:pages` indicates the number of pages to load.
    The value must be between `-1` and `100_000`. The default
    value is `1`.  A value of `-1` would load all the available
    pages which is useful if you want to keep the animation of
    the input image. The atom `:all` can be used in place of
    `-1` to indicate all pages should be loaded.

  #### PNG options

  * There are no PNG-specific image loading
    options.

  ### Returns

  * `image` or

  * raises an exception.

  """
  @doc subject: "Load and save"

  @spec open!(image_path :: Path.t(), options :: Options.Open.image_open_options()) ::
          Vimage.t() | no_return()

  def open!(image_path, options \\ []) do
    case open(image_path, options) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, {reason, image_path}
    end
  end

  @doc """
  Returns an image created from an SVG string.

  ### Arguments

  * `svg` is an SVG string.

  * `options` is a keyword list of options.

  ### Options

  * `:access` is the file access mode, either `:random`
    or `:sequential`. The default is `:random`.
    When `:sequential`, `Image` (via `Vix`) is able
    to support streaming transformations and optimise
    memory usage more effectively. However `:sequential`
    also means that some operations cannot be completed
    because they would require non-sequential access to
    the image. In these cases, `:random` access is required.

  * `:fail_on` sets the error level at which image
    loading and decoding will stop. The default is `:none`.
    Each error state implies all the states before it such
    that `:error` implies also `:truncated`.

  * `:scale` will scale the image on load. The value is
    a number greater than `0` and less than or equal
    to `1024` with a default of `1.0` meaning no scaling
    on load. Numbers less than `1.0` scale the image down
    so that a scale of `0.5` will halve the image size on
    load.

  ### Returns

  * `{:ok, image}` or

  * `{:error, reason}`

  """
  @doc subject: "Load and save", since: "0.32.0"

  @spec from_svg(svg :: binary(), options :: Open.image_open_options()) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def from_svg(svg, options \\ []) when is_binary(svg) do
    case Operation.svgload_buffer(svg, options) do
      {:ok, {image, _flags}} -> {:ok, image}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns an image created from an SVG string or
  raises an exception.

  ### Arguments

  * `svg` is an SVG string.

  * `options` is a keyword list of options.

  ### Options

  * `:access` is the file access mode, either `:random`
    or `:sequential`. The default is `:random`.
    When `:sequential`, `Image` (via `Vix`) is able
    to support streaming transformations and optimise
    memory usage more effectively. However `:sequential`
    also means that some operations cannot be completed
    because they would require non-sequential access to
    the image. In these cases, `:random` access is required.

  * `:fail_on` sets the error level at which image
    loading and decoding will stop. The default is `:none`.
    Each error state implies all the states before it such
    that `:error` implies also `:truncated`.

  * `:scale` will scale the image on load. The value is
    a number greater than `0` and less than or equal
    to `1024` with a default of `1.0` meaning no scaling
    on load. Numbers less than `1.0` scale the image down
    so that a scale of `0.5` will halve the image size on
    load.

  ### Returns

  * `image` or

  * raises an exception.

  """
  @doc subject: "Load and save", since: "0.32.0"

  @spec from_svg!(svg :: binary(), options :: Open.image_open_options()) ::
          Vimage.t() | no_return()

  def from_svg!(svg, options \\ []) when is_binary(svg) do
    case from_svg(svg, options) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Returns an image created from an in-memory binary representation
  of an image.

  The binary must be a complete formatted image such as that
  returned from `File.read!/1`.

  ### Arguments

  * `binary` is a binary representation of a formatted image
    including `.jpg`, `.png`, `.webp` and `.svg` binary data.

  * `options` is a keyword list of options. See `Image.open/2`
    for the list of applicable options.

  ### Returns

  * `{:ok, image}` or

  * `{:error, reason}`

  """
  @doc subject: "Load and save", since: "0.7.0"

  @spec from_binary(binary :: binary(), options :: Open.image_open_options()) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def from_binary(binary, options \\ []) when is_binary(binary) do
    with {:ok, options} <- Options.Open.validate_options(options) do
      options = Keyword.delete(options, :access)
      Vimage.new_from_buffer(binary, options)
    end
  end

  @doc """
  Returns an image created from an in-memory binary representation
  of an image or raises an exception.

  * `binary` is a binary representation of a formatted image
    including `.jpg`, `.png`, `.webp` and `.svg` binary data.

  ### Arguments

  * `binary` is a binary representation of a formatted image

  * `options` is a keyword list of options. See `Image.open/2`
    for the list of applicable options.

  ### Returns

  * `image` or

  * raises an exception.

  """
  @doc subject: "Load and save", since: "0.25.0"

  @spec from_binary!(binary :: binary(), options :: Open.image_open_options()) ::
          Vimage.t() | no_return()

  def from_binary!(binary, options \\ []) when is_binary(binary) do
    case from_binary(binary, options) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Returns an image from a [Kino](https://hex.pm/packages/kino) image
  input.

  ### Arguments

  * `image` is a a map returned from `Kino.Input.read(image)`
    via a `Kino.Input.image/1` input field. The data will have
    the following fields:
    * `:data` which contains the raw binary of the image
    * `:width` which is the width of the image in pixels
    * `:height` which is the height of the image in pixels
    * `:format` which is the image band format which must be `:rgb`

  * `options` is a keyword list of options

  ### Options

  * `:bands` indicates the integer number of bands (channels) in
    the image. The default is `3`.

  ### Notes

  * The image is assumed to contain pixel data that is in
    unsigned 8-bit format which is common for most web-oriented
    images.

  ### Returns

  * `{:ok, image}` or

  * `{:error, reason}`

  """
  @doc since: "0.27.0"

  @spec from_kino(image :: kino_image(), options :: Keyword.t()) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def from_kino(%{data: binary, width: width, height: height, format: :rgb}, options \\ []) do
    bands = Keyword.get(options, :bands, 3)
    image_format = :VIPS_FORMAT_UCHAR
    Vix.Vips.Image.new_from_binary(binary, width, height, bands, image_format)
  end

  @doc """
  Returns an image from a [Kino](https://hex.pm/packages/kino) image
  input or raises an exception.

  ### Arguments

  * `image` is a a map returned from `Kino.Input.read(image)`
    via a `Kino.Input.image/1` input field. The data will have
    the following fields:
    * `:data` which contains the raw binary of the image
    * `:width` which is the width of the image in pixels
    * `:height` which is the height of the image in pixels
    * `:format` which is the image band format which must be `:rgb`

  * `options` is a keyword list of options

  ### Options

  * `:bands` indicates the integer number of bands (channels) in
    the image. The default is `3`.

  ### Notes

  * The image is assumed to contain pixel data that is in
    unsigned 8-bit format which is common for most web-oriented
    images.

  ### Returns

  * `{:ok, image}` or

  * raises an exception.

  """
  @doc since: "0.27.0"

  @spec from_kino!(image :: kino_image(), options :: Keyword.t()) ::
          Vimage.t() | no_return()

  def from_kino!(%{data: binary, width: width, height: height, format: :rgb}, options \\ []) do
    case from_kino(%{data: binary, width: width, height: height, format: :rgb}, options) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Write an image to a file, a stream, an enumerable or
  to memory.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `image_path` is the file system path to an image
    file. It may also be a stream created with
    `File.stream!/3` or with `Stream.resource/3`, a
    `t:Plug.Conn.t/0` if `Plug` is configured or lastly,
    it can also be `:memory` in which case the image is
    written to a binary.

  * `options` is a keyword list of options. The default is
    `[]`.

  ### Options

  The available options depends on the type of image
  file being opened.

  #### All image types

  * `:strip_metadata` is a boolean indicating if all metadata
    is to be stripped from the image. The default is `false`.

  * `:background` is the background value to be used
    for any transparent areas of the image. Jpeg does
    not support alpha bands so a color value must be
    assigned.

  * `:quality` which influences image compression and
    is a integer in the range `1..100`. The default for
    most image formats is `75`. For HEIF files the default
    is `50`.For PNG files the `:quality` option is ignored.

  ### Streaming images and :memory images

  * `:suffix` must be specified so that the image is written
    in the correct format. For example: `suffix: ".jpg"`.

  #### JPEG images

  * `:progressive` is a boolean indicating if the image
    should be interleaved rather than baseline. Progressive
    has the advantage of perceived time for the initial
    image load and the cost of multiple decoding passes on
    the client. For many applications `:progressive` is
    to be preferred but validation of this assumption for
    specific use cases is required.

  * `:minimize_file_size` is a boolean indicating whether
    to apply a number of techniques to minimise the file
    size of the jpeg file at the cost of additional time to
    save the image. All metadata will also be removed.

  * `:icc_profile` indicates the icc profile to be attached
    to the output image. The value may be an inbuilt profile
    (`:none`, `:srgb`, `:cmyk`, `:p3`), the name of an icc
    profile in the systems profile directory or a full path
    to an icc profile file. The default is to use the icc
    profile of the input image if there is one.

  #### PNG images

  * `:progressive` which has the same meaning and values
      as for JPEG images.

  * `:minimize_file_size` is a boolean indicating whether
    to apply a number of techniques to minimise the file
    size of the `png` file at the cost of additional time to
    save the image. All metadata will also be removed.

  * `:compression`  is the compression factor which is an
    integer in the range `1..9`. The default is `6`.

  * `:effort` is an integer to adjust the level of CPU
    effort to reduce the file size. The value must be in the
    range `1..10`, the default is `7`.

  * `:icc_profile` indicates the icc profile to be attached
    to the output image. The value may be an inbuilt profile
    (`:none`, `:srgb`, `:cmyk`, `:p3`), the name of an icc
    profile in the systems profile directory or a full path
    to an icc profile file. The default is to use the icc
    profile of the input image if there is one.

  #### WEBP images

  * `:minimize_file_size` is a boolean which is most useful
    on animated `WebP`. It enables mixed encoding and optimise
    the file for minimum size at the cost of additional time
    to save the image. All metadata will also be removed.
    Using this parameter on a non-animated `webp` file will
    only remove the metadata as `:strip_metadata` would do.

  * `:effort` is an integer to adjust the level of CPU
    effort to reduce the file size.
    The value must be in the range `1..10`, the default
    is `7`.

  * `:icc_profile` indicates the icc profile to be attached
    to the output image. The value may be an inbuilt profile
    (`:none`, `:srgb`, `:cmyk`, `:p3`), the name of an icc
    profile in the systems profile directory or a full path
    to an icc profile file. The default is to use the icc
    profile of the input image if there is one.

  #### GIF options

  * `:interframe_maxerror` Maximum inter-frame error for transparency.
    The value must be in the range `0..32`.
    The default is `0`.
    By increasing this value, the encoder will try to take advantage
    from temporal redundancy between neighboring frames by enabling
    higher compression rates.

  * `:effort` is an integer to adjust the level of CPU
    effort to reduce the file size.
    The value must be in the range `1..10`, the default
    is `7`.

  #### HEIF images

  * `:compression` is the compression strategy to
    be applied. The allowable values are `:hevc`,
    `:avc`, `:jpeg` and `:av1`. The default is `:hevc`.

  * `:effort` is an integer to adjust the level of CPU
    effort to reduce the file size.
    The value can be in the range `1..10`, the default is
    `5`.

  * `:minimize_file_size` is a boolean indicating whether
    to apply a number of techniques to minimise the file
    size of the `heif` file at the cost of additional time to
    save the image. All metadata will also be removed.

  ### Merging image type options

  Options can also be grouped under an option key
  for each known image type. For example:

      Image.write(image, image_path, minimize_file_size: true,
        png: [compress: 60, lossy: true],
        jpg: [quality: 70],
        webp: [quality: 5])

  When validating options, the options applicable to the
  image type of `image_path` are merged into the rest of
  the supplied options.

  The valid image type option keys are `:jpg`, `.png`,
  `:gif`, `:tif`, `:webp` and `:heif`.

  This makes it easier to define a general purpose image
  processing pipeline that can still apply specific
  options when writing the image file.

  ### Returns

  * `{:ok, image}` (or `{:ok, binary}` is the destination is
    `:memory`) or

  * `{:error, reason}`

  """
  if match?({:module, _module}, Code.ensure_compiled(Plug)) do
    @spec write(
            image :: Vimage.t(),
            image_path :: Path.t() | Plug.Conn.t() | Enumerable.t() | File.Stream.t() | :memory,
            options :: Options.Write.image_write_options()
          ) ::
            {:ok, Vimage.t()} | {:ok, binary()} | {:error, error_message()}
  else
    @spec write(
            image :: Vimage.t(),
            image_path :: Path.t() | Enumerable.t() | File.Stream.t() | :memory,
            options :: Options.Write.image_write_options()
          ) ::
            {:ok, Vimage.t()} | {:ok, binary()} | {:error, error_message()}
  end

  @doc subject: "Load and save"
  def write(image, image_path, options \\ [])

  def write(%Vimage{} = image, image_path, options) when is_binary(image_path) do
    with {:ok, options} <- Options.Write.validate_options(image_path, options) do
      image_path
      |> String.split("[", parts: 2)
      |> write_path(image, options)
    end
  end

  if match?({:module, _module}, Code.ensure_compiled(Plug)) do
    def write(%Vimage{} = image, %Plug.Conn{} = conn, options) do
      with {:ok, options} <- Options.Write.validate_options(options, :require_suffix) do
        {suffix, options} = Keyword.pop(options, :suffix)
        options = suffix <> loader_options(options)

        result =
          image
          |> Vimage.write_to_stream(options)
          |> Enum.reduce_while(conn, fn chunk, conn ->
            case Plug.Conn.chunk(conn, chunk) do
              {:ok, conn} ->
                {:cont, conn}

              {:error, :closed} = error ->
                {:halt, error}
            end
          end)

        with %Plug.Conn{} <- result do
          {:ok, image}
        end
      end
    end
  end

  def write(%Vimage{} = image, %module{} = stream, options)
      when module in [File.Stream, Stream] do
    with {:ok, options} <- Options.Write.validate_options(options, :require_suffix) do
      case write_stream(image, stream, options) do
        :ok -> {:ok, image}
        other -> other
      end
    end
  end

  def write(%Vimage{} = image, :memory, options) do
    with {:ok, options} <- Options.Write.validate_options(options, :require_suffix) do
      {suffix, options} = Keyword.pop(options, :suffix)
      options = suffix <> loader_options(options)
      Vimage.write_to_buffer(image, options)
    end
  end

  defp write_stream(image, stream, options) do
    {suffix, options} = Keyword.pop(options, :suffix)
    options = suffix <> loader_options(options)

    image
    |> Vimage.write_to_stream(options)
    |> Stream.into(stream)
    |> Stream.run()
  rescue
    e in Vix.Vips.Image.Error ->
      {:error, e.message}
  end

  defp write_path([image_path], image, options) do
    options = build_option_string(options)

    case Vimage.write_to_file(image, image_path <> options) do
      :ok -> {:ok, image}
      other -> other
    end
  end

  defp write_path([image_path, open_options], image, options) do
    write_options = String.trim_trailing(open_options, "]")
    options = build_option_string(write_options, options)

    case Vimage.write_to_file(image, image_path <> options) do
      :ok -> {:ok, image}
      other -> other
    end
  end

  @doc """
  Write an image to a file, a stream, an enumerable or
  to memory returning the image or raising an exception.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `image_path` is the file system path to an image
    file. It may also be a stream created with
    `File.stream!/3` or with `Stream.resource/3`. Lastly,
    it can also be `:memory` in which case the image is
    written to a memory buffer.

  * `options` is a keyword list of options.
    See `Image.write/2`.

  ### Returns

  * `image` (or a binary is the destination is `:memory`) or

  * raises an exception.

  """
  @doc subject: "Load and save"

  @spec write!(
          image :: Vimage.t(),
          image_path_or_stream :: Path.t() | Plug.Conn.t() | Enumerable.t() | File.Stream.t(),
          options :: Options.Write.image_write_options()
        ) ::
          Vimage.t() | binary() | no_return()

  def write!(%Vimage{} = image, image_path, options \\ []) do
    case write(image, image_path, options) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, {reason, image_path}
    end
  end

  @doc """
  Convert an image into an enumerable
  stream.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `options` is a keyword list of options.

  ### Options

  * `:buffer_size` is the size in bytes for
    each chunk in the stream being written.
    Some services, like AWS S3, require a minimum
    5 MiB per chunk to be delivered and this option
    can be used to satisfy that requirement.

  For additional options see `Image.write/3`.

  ### Returns

  * An `t:Enumerable.t/0` suitable for
    streaming to an external service such as
    S3, Minio or any other enumerable consumer.

  > #### S3 and Buffer Size {: .info}
  > You may get an error from S3 if you do not specify a buffer size.
  >
  > ```text
  > EntityTooSmall: Your proposed upload is smaller than the minimum allowed object size.
  > ```
  >
  > Since AWS S3 requires multipart uploads to be 5MiB per chunk, we specify
  > the `:buffer_size` option to `Image.stream!/2`.

  ### Example

  In this example an image is opened, resized
  and then streamed into AWS S3:

      "some/image.jpg"
      |> Image.open!()
      |> Image.resize!(200)
      |> Image.stream!(suffix: ".jpg", buffer_size: 5_242_880)
      |> ExAws.S3.upload("images", "some_object_name.jpg")
      |> ExAws.request()

  """
  @doc subject: "Load and save"

  @spec stream!(Vimage.t(), options :: Options.Write.image_write_options()) :: Enumerable.t()
  def stream!(%Vimage{} = image, options \\ []) do
    with {:ok, options} <- Options.Write.validate_options(options, :require_suffix) do
      {suffix, options} = Keyword.pop(options, :suffix)
      {buffer_size, options} = Keyword.pop(options, :buffer_size, :unbuffered)
      options = suffix <> loader_options(options)

      stream = Vimage.write_to_stream(image, options)

      if buffer_size == :unbuffered || buffer_size == 0 do
        stream
      else
        buffer!(stream, buffer_size)
      end
    else
      {:error, reason} -> raise Image.Error, reason
    end
  end

  # Rebuffers a stream into chunks of a minimum size.
  # This is useful when streaming to AWS S3 which requires
  # a minimum 5 MiB chunk size for multi-part uploads.

  defp buffer!(stream, buffer_size) do
    chunker = fn bin, acc ->
      acc_size = IO.iodata_length(acc)

      if IO.iodata_length(bin) + acc_size >= buffer_size do
        size = buffer_size - acc_size
        <<chunk::binary-size(size), rest::binary>> = bin
        {:cont, IO.iodata_to_binary([acc, chunk]), [rest]}
      else
        {:cont, [acc, bin]}
      end
    end

    final = fn
      [] -> {:cont, []}
      acc -> {:cont, IO.iodata_to_binary(acc), []}
    end

    Stream.chunk_while(stream, [], chunker, final)
  end

  @doc """
  Scans the `condition_image` cond and uses it to select
  pixels from either the `if_image` or the `else_image`.

  Non-zero means copy a pixel from `if_image`, `0` means
  copy a pixel from `else_image`.

  ### Arguments

  * `condition_image` is any image. Typically it is an image
    formed by the relation operations such as `Image.Math.greater_than/2`.

  * `if_image_or_color` is either an `t:Vimage.t/0` or
    a `t:Image.Color.t/0`. If a color is provided then
    an image is constructed with the same shape as `condition_image`
    filled with the provided color.

  * `else_image_or_color` is either an `t:Vimage.t/0` or
    a `t:Image.Color.t/0`. If a color is provided then
    an image is constructed with the same shape as `condition_image`
    filled with the provided color.

  * `options` is a keyword list of options.

  ### Options

  * `:blend` is a boolean indicating if a the operation should blend
    smoothly between `then` and `else` images. The default is `false`.

  ### Returns

  * `{:ok, image}` or

  * `{:error, reason}`.

  ### Notes

  Any image can have either 1 band or `n` bands, where `n`
  is the same for all the non-1-band images. Single band
  images are then effectively copied to make n-band images.

  Images `if_image` and `else_image` are cast up to the
  smallest common format. The `condition_image` is cast to
  `{:u, 8}`.

  If the images differ in size, the smaller images are
  enlarged to match the largest by adding zero pixels along
  the bottom and right.

  The output image is calculated pixel by pixel as:

      (condition_image / 255) * if_image + (1 - condition_image / 255) * else_image

  """
  @doc subject: "Operation", since: "0.13.0"

  @spec if_then_else(
          condition_image :: Vimage.t(),
          if_image :: image_or_color(),
          else_image :: image_or_color(),
          options :: Keyword.t()
        ) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def if_then_else(condition_image, if_image_or_color, else_image_or_color, options \\ [])

  def if_then_else(
        %Vimage{} = condition_image,
        %Vimage{} = if_image,
        %Vimage{} = else_image,
        options
      ) do
    blend = Keyword.get(options, :blend, false)
    Operation.ifthenelse(condition_image, if_image, else_image, blend: blend)
  end

  def if_then_else(%Vimage{} = condition_image, if_color, else_image_or_color, options)
      when is_color(if_color) do
    with {:ok, if_color} <- Color.validate_color(if_color),
         {:ok, if_image} <- new(condition_image, color: if_color) do
      if_then_else(condition_image, if_image, else_image_or_color, options)
    end
  end

  def if_then_else(%Vimage{} = condition_image, if_image_or_color, else_color, options)
      when is_color(else_color) do
    with {:ok, else_color} <- Color.validate_color(else_color),
         {:ok, else_image} <- new(condition_image, color: else_color) do
      if_then_else(condition_image, if_image_or_color, else_image, options)
    end
  end

  @doc """
  Scans the condition image cond and uses it to select
  pixels from either the `if_image` or the `else_image`.
  Raise an exception on error.

  Non-zero means copy a pixel from `if_image`, `0` means
  copy a pixel from `else_image`.

  ### Arguments

  * `condition_image` is any image. Typically it is an image
    formed by the relation operations such as `Image.Math.greater_than/2`.

  * `if_image_or_color` is either an `t:Vimage.t/0` or
    a `t:Image.Color.t/0`. If a color is provided then
    an image is constructed with the same shape as `condition_image`
    filled with the provided color.

  * `else_image_or_color` is either an `t:Vimage.t/0` or
    a `t:Image.Color.t/0`. If a color is provided then
    an image is constructed with the same shape as `condition_image`
    filled with the provided color.

  ### Returns

  * `image` or

  * raises an exception.

  ### Notes

  Any image can have either 1 band or `n` bands, where `n`
  is the same for all the non-1-band images. Single band
  images are then effectively copied to make n-band images.

  Images `if_image` and `else_image` are cast up to the
  smallest common format. The `condition_image` is cast to
  `{:u, 8}`.

  If the images differ in size, the smaller images are
  enlarged to match the largest by adding zero pixels along
  the bottom and right.

  The output image is calculated pixel by pixel as:

      (condition_image / 255) * if_image + (1 - condition_image / 255) *`else_image`

  """
  @doc subject: "Operation", since: "0.30.0"

  @spec if_then_else!(
          condition_image :: Vimage.t(),
          if_image :: image_or_color(),
          else_image :: image_or_color()
        ) ::
          Vimage.t() | no_return()

  def if_then_else!(%Vimage{} = condition_image, if_color, else_image_or_color) do
    case if_then_else(condition_image, if_color, else_image_or_color) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Automatically determine the chroma key
  color of an image.

  The top left 10x10 pixels of the flattened
  image are averaged to produce a color sample
  that can then be used by `Image.chroma_mask/2`,
  `Image.chroma_key/2` and `Image.trim/2`.

  ### Argument

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * An RGB color as a three-element list of
    integers.

  """

  # Original python code
  #   this will be an RGB triple eg. [10, 10, 240]
  #   key_colour = [i.avg() for i in foreground.crop(0, 0, 10, 10).bandsplit()]

  @doc subject: "Operation", since: "0.13.0"

  @spec chroma_color(image :: Vimage.t()) :: Color.t()
  def chroma_color(%Vimage{} = image) do
    with {:ok, flattened} <- flatten(image),
         {:ok, cropped} <- Image.crop(flattened, 0, 0, 10, 10) do
      average(cropped)
    end
  end

  defp max_band_index(image) do
    Image.bands(image) - 1
  end

  defp band_range(image) do
    0..max_band_index(image)
  end

  @doc """
  Return a chroma-based masked image.

  Chroma masking is the process of removing a background color
  from an image and returning the remaining content as an alpha
  mask.

  The masking is done in the LCh color space since it's perceptually
  more uniform.  The returned mask in reverted to the interpretation
  of the original image.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `options` is a keyword list of options.

  ### Options

  There are two masking strategies available: the
  thresholding strategy (default) and the color
  range strategy.

  #### Threshold strategy

  * `:color` is an RGB color which represents the the
    chroma key to be masked. The color can be an
    integer between `0..255`, a three-element list of
    integers representing an RGB color or an atom
    representing a CSS color name. The default is
    `:auto` in which the average of the top left `10x10`
    pixels of the image is used.

  * `:threshold`is a positive integer to indicate the
    threshold around `:color` when calculating the mask.
    The default is `20`.

  #### Color range strategy

  * `:greater_than` is an RGB color which represents the upper
     end of the color range to be masked. The color can be an
     integer between `0..255`, a three-element list of
     integers representing an RGB color or an atom
     representing a CSS color name.

   * `:less_than` is an RGB color which represents the lower
     end of the color range to be masked. The color can be an
     integer between `0..255`, a three-element list of
     integers representing an RGB color or an atom
     representing a CSS color name.

  """

  # Original python code for thresholding from: https://github.com/libvips/libvips/discussions/3097#discussioncomment-3892994
  #    threshold = 20
  #    mask = ((foreground - key_colour) ** 2).bandmean() > (3 * threshold ** 2)

  @doc subject: "Operation", since: "0.13.0"

  @spec chroma_mask(image :: Vimage.t(), options :: ChromaKey.chroma_key_options() | map()) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def chroma_mask(image, options \\ [])

  def chroma_mask(%Vimage{} = image, options) when is_list(options) do
    with {:ok, options} <- Options.ChromaKey.validate_options(options) do
      chroma_mask(image, options)
    end
  end

  def chroma_mask(%Vimage{} = image, %{color: color, threshold: threshold}) do
    alias Image.Math

    color = maybe_calculate_color(image, color)

    image
    |> Math.subtract!(color)
    |> Math.pow!(2)
    |> Operation.bandmean!()
    |> Math.greater_than!(3 * threshold ** 2)
    |> wrap(:ok)
  end

  def chroma_mask(%Vimage{} = image, %{greater_than: greater_than, less_than: less_than}) do
    alias Image.Math

    with {:ok, greater} <- Math.greater_than(image, greater_than),
         {:ok, less} = Math.less_than(image, less_than),
         {:ok, color_mask} = Math.boolean_and(greater, less),
         {:ok, mask} = Vix.Vips.Operation.bandbool(color_mask, :VIPS_OPERATION_BOOLEAN_AND) do
      Vix.Vips.Operation.invert(mask)
    end
  end

  defp maybe_calculate_color(image, :auto), do: chroma_color(image)
  defp maybe_calculate_color(_image, color), do: color

  @doc """
  Return a chroma-based masked image or raises
  an exception.

  Chroma masking is the process of removing a background color
  from an image and returning the remaining content as an alpha
  mask.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `options` is a keyword list of options.

  ### Options

  There are two masking strategies available: the
  thresholding strategy (default) and the color
  range strategy.

  #### Threshold strategy

  * `:color` is an RGB color which represents the the
    chroma key to be masked. The color can be an
    integer between `0..255`, a three-element list of
    integers representing an RGB color or an atom
    representing a CSS color name. The default is
    `:auto` in which the average of the top left `10x10`
    pixels of the image is used.

  * `:threshold`is a positive integer to indicate the
    threshold around `:color` when calculating the mask.
    The default is `20`.

  #### Color range strategy

  * `:greater_than` is an RGB color which represents the upper
     end of the color range to be masked. The color can be an
     integer between `0..255`, a three-element list of
     integers representing an RGB color or an atom
     representing a CSS color name.

   * `:less_than` is an RGB color which represents the lower
     end of the color range to be masked. The color can be an
     integer between `0..255`, a three-element list of
     integers representing an RGB color or an atom
     representing a CSS color name.

  """
  @doc subject: "Operation", since: "0.13.0"

  @spec chroma_mask!(image :: Vimage.t(), options :: ChromaKey.chroma_key_options()) ::
          Vimage.t() | no_return()

  def chroma_mask!(%Vimage{} = image, options \\ []) do
    case chroma_mask(image, options) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Chroma key an image.

  Chroma keying is the process of removing a background color
  from an image resulting in a foreground image that may
  be composited over another image.

  If the image already has an alpha band then the
  image is flattened before adding the image mask
  as a new alpha band.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `options` is a keyword list of options.

  ### Options

  There are two masking strategies available: the
  thresholding strategy (default) and the color
  range strategy.

  #### Threshold strategy

  * `:color` is an RGB color which represents the the
    chroma key to be masked. The color can be an
    integer between `0..255`, a three-element list of
    integers representing an RGB color or an atom
    representing a CSS color name. The default is
    `:auto` in which the average of the top left `10x10`
    pixels of the image is used.

  * `:threshold` is a positive integer to indicate the
    threshold around `:color` when calculating the mask.
    The default is `20`.

  #### Color range strategy

  * `:greater_than` is an RGB color which represents the upper
     end of the color range to be masked. The color can be an
     integer between `0..255`, a three-element list of
     integers representing an RGB color or an atom
     representing a CSS color name.

  *  `:less_than` is an RGB color which represents the lower
     end of the color range to be masked. The color can be an
     integer between `0..255`, a three-element list of
     integers representing an RGB color or an atom
     representing a CSS color name.

  """
  @doc subject: "Operation", since: "0.13.0"

  @spec chroma_key(image :: Vimage.t(), options :: ChromaKey.chroma_key_options()) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def chroma_key(%Vimage{} = image, options \\ []) do
    with {:ok, options} <- Options.ChromaKey.validate_options(options),
         {:ok, mask} <- chroma_mask(image, options),
         {:ok, flattened} <- flatten(image) do
      Operation.bandjoin([flattened, mask])
    end
  end

  @doc """
  Chroma key an image and return an image or
  raise an exception.

  Chroma keying is the process of removing a background color
  from an image resulting in a foreground image that may
  be composited over another image.

  If the image already has an alpha band then the
  image is flattened before adding the image mask
  as a new alpha band.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `options` is a keyword list of options.

  ### Options

  There are two masking strategies available: the
  thresholding strategy (default) and the color
  range strategy.

  #### Threshold strategy

  * `:color` is an RGB color which represents the the
    chroma key to be masked. The color can be an
    integer between `0..255`, a three-element list of
    integers representing an RGB color or an atom
    representing a CSS color name. The default is
    `:auto` in which the average of the top left `10x10`
    pixels of the image is used.

  * `:threshold` is a positive integer to indicate the
    threshold around `:color` when calculating the mask.
    The default is `20`.

  #### Color range strategy

  * `:greater_than` is an RGB color which represents the upper
     end of the color range to be masked. The color can be an
     integer between `0..255`, a three-element list of
     integers representing an RGB color or an atom
     representing a CSS color name.

  *  `:less_than` is an RGB color which represents the lower
     end of the color range to be masked. The color can be an
     integer between `0..255`, a three-element list of
     integers representing an RGB color or an atom
     representing a CSS color name.

  """
  @doc subject: "Operation", since: "0.13.0"

  @spec chroma_key!(image :: Vimage.t(), options :: ChromaKey.chroma_key_options()) ::
          Vimage.t() | no_return()

  def chroma_key!(%Vimage{} = image, options \\ []) do
    case chroma_key(image, options) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Applies a gaussian blur to an image.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `options` is a keyword list of options.

  ### Options

  * `:sigma` is the `float` size of the mask
    to use. A larger number makes the image more
    blurry. A range between `1.0` and `10.0`
    is normally appropriate. The default is
    `#{@default_blur_sigma}`.

  * `:min_amplitude` is a `float` that determines
    the accuracy of the mask. The default is `0.2`.
    A smaller number will generate a larger, more
    accurate mask,

  ### Returns

  * `{:ok, blurred_image}` or

  * `{:error reason}`

  """
  @doc subject: "Operation", since: "0.13.0"

  @spec blur(image :: Vimage.t(), options :: Options.Blur.blur_options()) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def blur(%Vimage{} = image, options \\ []) do
    with {:ok, options} <- Options.Blur.validate_options(options) do
      Operation.gaussblur(image, options.sigma, "min-ampl": options.min_amplitude)
    end
  end

  @doc """
  Applies a gaussian blur to an image.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `options` is a keyword list of options.

  ### Options

  * `:sigma` is the `float` size of the mask
    to use. A larger number makes the image more
    blurry. A range between `1.0` and `10.0`
    is normally appropriate. The default is
    `#{@default_blur_sigma}`.

  * `:min_amplitude` is a `float` that determines
    the accuracy of the mask. The default is `0.2`.
    A smaller number will generate a larger, more
    accurate mask,

  ### Returns

  * `blurred_image` or

  * raises an exception.

  """
  @doc subject: "Operation", since: "0.13.0"

  @spec blur!(image :: Vimage.t(), options :: Options.Blur.blur_options()) ::
          Vimage.t() | no_return()

  def blur!(%Vimage{} = image, options \\ []) do
    case blur(image, options) do
      {:ok, blurred_image} -> blurred_image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Sharpens an image.

  Selectively sharpens the `L` channel of a LAB image. `image`
  is converted to `:labs` for sharpening and the converted back
  to its original interpretation.

  The operation performs a gaussian blur and subtracts from `image` to generate a
  high-frequency signal. This signal is passed through a lookup table formed
  from the five parameters and then added back to `image`.

  The lookup table is formed like this:

  ```
                      ^
                   y2 |          -----------
                      |         /
                      |        / slope m2
                      |    .../
              -x1     | ...   |
  -------------------...---------------------->
              |   ... |      x1
              |... slope m1
              /       |
             / m2     |
            /         |
           /          |
          /           |
         /            |
  ______/             | -y3
                      |
  ```

  Where:

  * `m1` is `:flat_amount`
  * `m2` is `:jagged_amount`
  * `x1` is `:threshold`
  * `y2` is `:max_brightening`
  * `y3` is `:max_darkening`

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `options` is a keyword list of options.

  ### Options

  * `:jagged_amount` is the primary means of specifing how much
    sharpening to apply. Shaprening is applied to the jagged areas
    of the image. It is a float greater or equal to `0.0`
    with a default of `3.0`.

  * `:flat_amount` is the specifies how much
    sharpening to apply to flat areas of the image. It is a float
    greater or equal to `0.0` with a default of `0.0`.

  * `:threshold` indicates where the transition from the flat
    part of the image to the jaggy part of the image is to be
    considered on the curve. It is a float amount greater than
    or equal to `0.0` with a default of `2.0`.

  * `:max_brightening` specifies how much the image may be
    brightened as part of the sharpening process. It is a positive
    integer greater than or equal to `0`. The default is `10`.

  * `:max_darkening` specifies how much the image may be
    darkened as part of the sharpening process. It is a positive
    integer greater than or equal to `0`. The default is `20`.

  * `:sigma` changes the width of the sharpening fringe and can be
    adjusted according to the output printing resolution. As an approximate
    guideline, use `0.5` for 4 pixels/mm (display resolution),
    `1.0` for 12 pixels/mm and `1.5` for 16 pixels/mm (300 dpi == 12
    pixels/mm). These figures refer to the image raster, not the half-tone
    resolution. The default is `0.5`.

  ### Returns

  * `{:ok, sharpened_image}` or

  * `{:error reason}`

  ### Output sharpening

  For screen output sharpening the default options are recommended.
  Adjust `:sigma` for other output devices as required.

  """
  @doc subject: "Operation"
  @doc since: "0.35.0"

  @spec sharpen(image :: Vimage.t(), options :: Options.Sharpen.sharpen_options()) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def sharpen(image, options \\ []) do
    with {:ok, options} <- Options.Sharpen.validate_options(options) do
      Operation.sharpen(image,
        sigma: options.sigma,
        x1: options.threshold,
        y2: options.max_brightening,
        y3: options.max_darkening,
        m1: options.flat_amount,
        m2: options.jagged_amount
      )
    end
  end

  @doc """
  Sharpens an image or raises an exception.

  Selectively sharpens the `L` channel of a LAB image. `image`
  is converted to `:labs` for sharpening and the converted back
  to its original interpretation.

  The operation performs a gaussian blur and subtracts from `image` to generate a
  high-frequency signal. This signal is passed through a lookup table formed
  from the five parameters and then added back to `image`.

  The lookup table is formed like this:

  ```
                      ^
                   y2 |          -----------
                      |         /
                      |        / slope m2
                      |    .../
              -x1     | ...   |
  -------------------...---------------------->
              |   ... |      x1
              |... slope m1
              /       |
             / m2     |
            /         |
           /          |
          /           |
         /            |
  ______/             | -y3
                      |
  ```

  Where:

  * `m1` is `:flat_amount`
  * `m2` is `:jagged_amount`
  * `x1` is `:threshold`
  * `y2` is `:max_brightening`
  * `y3` is `:max_darkening`

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `options` is a keyword list of options.

  ### Options

  * `:jagged_amount` is the primary means of specifing how much
    sharpening to apply. Shaprening is applied to the jagged areas
    of the image. It is a float greater or equal to `0.0`
    with a default of `3.0`.

  * `:flat_amount` is the specifies how much
    sharpening to apply to flat areas of the image. It is a float
    greater or equal to `0.0` with a default of `0.0`.

  * `:threshold` indicates where the transition from the flat
    part of the image to the jaggy part of the image is to be
    considered on the curve. It is a float amount greater than
    or equal to `0.0` with a default of `2.0`.

  * `:max_brightening` specifies how much the image may be
    brightened as part of the sharpening process. It is a positive
    integer greater than or equal to `0`. The default is `10`.

  * `:max_darkening` specifies how much the image may be
    darkened as part of the sharpening process. It is a positive
    integer greater than or equal to `0`. The default is `20`.

  * `:sigma` changes the width of the sharpening fringe and can be
    adjusted according to the output printing resolution. As an approximate
    guideline, use `0.5` for 4 pixels/mm (display resolution),
    `1.0` for 12 pixels/mm and `1.5` for 16 pixels/mm (300 dpi == 12
    pixels/mm). These figures refer to the image raster, not the half-tone
    resolution. The default is `0.5`.

  ### Returns

  * `sharpened_image` or

  * raises an exception.

  ### Output sharpening

  For screen output sharpening the default options are recommended.
  Adjust `:sigma` for other output devices as required.

  """
  @doc subject: "Operation"
  @doc since: "0.35.0"

  @spec sharpen!(image :: Vimage.t(), options :: Options.Sharpen.sharpen_options()) ::
          Vimage.t() | no_return()

  def sharpen!(image, options \\ []) do
    case sharpen(image, options) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Feather (blur the edges) of an image
  mask.

  Applies a gaussian blur to a one-band image
  or the alpha band of a multi-band image
  that can be used to smooth the blending of
  one image into another.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0` that is either
    a single band image or an image with an alpha band.

  * `options` is a keyword list of options.

  ### Options

  * `:sigma` is the `float` size of the mask
    to use. A larger number makes the image more
    blurry. A range between `1.0` and `10.0`
    is normally appropriate. The default is
    `#{@default_blur_sigma}`.

  * `:min_amplitude` is a `float` that determines
    the accuracy of the mask. The default is `0.2`.
    A smaller number will generate a larger, more
    accurate mask,

  ### Returns

  * `{:ok, blurred_mask_image}` or

  * `{:error, reason}`

  """
  @doc subject: "Operation", since: "0.13.0"

  @spec feather(image :: Vimage.t(), options :: Options.Blur.blur_options()) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def feather(%Vimage{} = image, options \\ []) do
    with {:ok, options} <- Options.Blur.validate_options(options) do
      cond do
        has_alpha?(image) ->
          {image, alpha} = split_alpha(image)
          {:ok, feathered} = feather(alpha, options)
          Operation.bandjoin([image, feathered])

        bands(image) == 1 ->
          margin = options.sigma * 2

          crop!(image, margin, margin, width(image) - 2 * margin, height(image) - 2 * margin)
          |> Operation.embed!(margin, margin, width(image), height(image))
          |> blur!(options)
          |> wrap(:ok)

        true ->
          {:error, "Image has no alpha band and is not a single band image"}
      end
    end
  end

  @doc """
  Feather (blur the edges) of an image
  mask returning an image or raising an
  exception.

  Applies a gaussian blur to a one-band image
  or the alpha band of a multi-band image
  that can be used to smooth the blending of
  one image into another.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0` that is either
    a single band image or an image with an alpha band.

  * `options` is a keyword list of options.

  ### Options

  * `:sigma` is the `float` size of the mask
    to use. A larger number makes the image more
    blurry. A range between `1.0` and `10.0`
    is normally appropriate. The default is
    `#{@default_blur_sigma}`.

  * `:min_amplitude` is a `float` that determines
    the accuracy of the mask. The default is `0.2`.
    A smaller number will generate a larger, more
    accurate mask,

  ### Returns

  * `{:ok, blurred_mask_image}` or

  * `{:error, reason}`

  """
  @doc subject: "Operation", since: "0.13.0"

  @spec feather!(image :: Vimage.t(), options :: Options.Blur.blur_options()) ::
          Vimage.t() | no_return()

  def feather!(%Vimage{} = image, options \\ []) do
    case feather(image, options) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Returns the average color of an image.

  The average is calculated for each band
  of an image and then combined.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * A list of average pixel values which can
    be interpreted as the average color of the
    image.

  ### Example

        iex> Image.open!("./test/support/images/Hong-Kong-2015-07-1998.jpg")
        ...> |> Image.average()
        [66, 86, 106]

  """
  @doc since: "0.27.0"

  @spec average(Vimage.t()) :: Color.t() | {:error, error_message}
  def average(%Vimage{} = image) do
    with {:ok, flattened} <- flatten(image) do
      for i <- band_range(flattened) do
        image[i]
        |> Operation.avg!()
        |> round()
      end
    end
  end

  @doc """
  Returns the average color of an image or
  raises and exception.

  The average is calculated for each band
  of an image and then combined.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * A list of average pixel values which can
    be interpreted as the average color of the
    image.

  ### Example

        iex> Image.open!("./test/support/images/Hong-Kong-2015-07-1998.jpg")
        ...> |> Image.average!()
        [66, 86, 106]

  """
  @doc since: "0.27.0"

  @spec average!(Vimage.t()) :: Color.t() | no_return()
  def average!(%Vimage{} = image) do
    case average(image) do
      {:error, reason} -> raise Image.Error, reason
      color -> color
    end
  end

  @doc """
  Add an alpha band to an image.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `alpha_image` is any single-band image
    that will be added as an alpha image to
    `image`

  OR

  * an integer in the range `0..255` that represents
    the level of transparency of the alpha band. `0`
    represents fully opaque and `255` represents fully
    transparent. The atoms `:opaque` and `:transparent`
    may also be provided representing the values of
    `0` and `255` respectively.

  ### Returns

  * `{:ok, image_with_added_alpha_band}` or

  * `{:error, reason}`

  """
  @doc subject: "Operation", since: "0.13.0"

  @spec add_alpha(image :: Vimage.t(), alpha_image :: Vimage.t() | transparency()) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def add_alpha(%Vimage{} = image, %Vimage{} = alpha_image) do
    cond do
      has_alpha?(image) ->
        {:error, "Image already has an alpha band"}

      bands(alpha_image) > 1 ->
        {:error, "Alpha image has more than one band"}

      true ->
        Operation.bandjoin([image, alpha_image])
    end
  end

  def add_alpha(%Vimage{} = image, transparency) when transparency in 0..255 do
    with {:ok, alpha_image} <- Image.new(image, bands: 1, color: transparency) do
      add_alpha(image, alpha_image)
    end
  end

  def add_alpha(%Vimage{} = image, :transparent) do
    add_alpha(image, @transparent)
  end

  def add_alpha(%Vimage{} = image, :opaque) do
    add_alpha(image, @opaque_)
  end

  @doc """
  Add an alpha band to an image.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `alpha_image` is any single-band image
    that will be added as an alpha image to
    `image`

  OR

  * `:color` which defines the color of the alpha
    image. This can be specified as a single integer
    which will be applied to all bands, or a list of
    integers representing the color for each
    band. The default is `0`, meaning black. The color
    can also be supplied as a CSS color name as a
    string or atom. For example: `:misty_rose`. See
    `Image.Color.color_map/0` and `Image.Color.rgb_color/1`.

  ### Note

  If `color` is provided then the alpha layer determines
  the level of transparency of `image`.

  White (RGB color 255) means that `image` will be opaque.
  Black (the default, RGB 0) means that `image` will be transparent.
  Other colors will determine the level of transparency
  between the two.

  ### Returns

  * `image_with_added_alpha_band` or

  * raises an exception.

  """
  @doc subject: "Operation", since: "0.13.0"

  @spec add_alpha!(image :: Vimage.t(), alpha_image :: Vimage.t() | Image.Color.t()) ::
          Vimage.t() | no_return()

  def add_alpha!(%Vimage{} = image, alpha_image) do
    case add_alpha(image, alpha_image) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Split an image to separate the alpha band
  from the other image bands.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * `{image_without_alpha, alpha_band}` or

  * `{image, nil}` if there is no
    alpha band detected.

  """
  @doc subject: "Operation", since: "0.13.0"

  @spec split_alpha(image :: Vimage.t()) :: {bands :: Vimage.t(), alpha :: Vimage.t() | nil}
  def split_alpha(%Vimage{} = image) do
    if has_alpha?(image) do
      alpha_band = image[alpha_band(image)]
      image = Operation.extract_band!(image, 0, n: Image.bands(image) - 1)
      {image, alpha_band}
    else
      {image, nil}
    end
  end

  @doc """
  Compose two images together to form a new image.

  ### Arguments

  * `base_image` is any `t:Vix.Vips.Image.t/0`.

  * `overlay_image` is any `t:Vix.Vips.Image.t/0` that will
    be composed over the top of `base_image`. It can also
    be a list of `t:composition/0`s that allow for multiple
    images to be composed in a single call.

  * `options` is a keyword list of options.

  ### Options for a single overlay image

  * `:blend_mode` is the manner in which the two
    images are composited. See `t:Image.BlendMode.t/0`.
    The default is `:over` which is the most common blend
    mode.

  * `:x` is the offset (0-based) which, if zero or positive,
    from the *left* of the `base_image`. If negative is is
    the offset from the *right* of the `base_image`.
    where the `overlay_image` will be placed. It may also be
    one of the keywords `:left`, `:right` or `:center`. The
    default is `:center`.

  * `:y` is the offset (0-based) which, if zero or positive,
    from the *top* of the `base_image`. If negative is is
    the offset from the *bottom* of the `base_image`.
    where the `overlay_image` will be placed.  It may also be
    one of the keywords `:top`, `:bottom` or `:middle`. The
    default is `:middle`.

  ### Composition list options

  When `overlay_image` is an `image_list`, each entry in
  the list is either a `t:Vix.Vips.Image.t/0` or a
  `t:Image.composition_list/0`. A composition supports the specification
  of how a particular image is composed onto the base image.

  * `:x` describes the absolute `x` offset on the
    base image where this image will be placed. If
    this option is set to `:left`, `:center` or
    `:right` then the `x` position will be calculated
    relative to the base image. If `:x` is nil
    (the default) then the image will be placed according
    to the relative offset of the previously composed
    image using `:dx`.

  * `:y` describes the absolute `y` offset on the
    base image where this image will be placed. If
    this option is set to `:top`, `:middle` or
    `:bottom` then the `y` position will be calculated
    relative to the base image. If `:y` is nil
    (the default) then the image will be placed according
    to the relative offset of the previously composed
    image using `:dy`.

  * `:dx` describes the relative offset used to calculate
    the `x` value. `:dx` is an integer offset from the
    edge of the previously composed image. Which edge is
    determined by the `:x_baseline` option. If `:x` is also
    specified then `:x` is first calculated, then `:dx` is
    added to it. In this case, `:x_baseline` is ignored.

  * `:dy` describes the relative offset used to calculate
    the `y` value. `:dy` is an integer offset from the
    edge of the previously composed image. Which edge is
    determined by the `:y_baseline` option. If `:y` is also
    specified then `:y` is first calculated, then `:dy` is
    added to it. In this case, `:x_baseline` is ignored.

  * `:blend_mode` is the `t:Image.BlendMode.t/0` used when
    composing this image over its base image. The default
    is `:over` which is appropriate for most use cases.

  * `:x_baseline` establishes the baseline on the
    previously composed image from which `:dx` is
    calculated. The default is `:right`.

  * `:y_baseline` establishes the baseline on the
    previously composed image from which `:dy` is
    calculated. The default is `:bottom`.

  ### Returns

  * `{:ok, composed_image}` or

  * `{:error, reason}`

  ### Examples

      # Compose images over a base image using
      # absolute coordinates from the base image
      # to place each overlay image.

      #=> {:ok, image} = Image.compose(base_image, polygon, x: :middle, y: :top)
      #=> {:ok, image} = Image.compose(image, explore_new, x: 260, y: 200)
      #=> {:ok, image} = Image.compose(image, places, x: 260, y: 260)
      #=> {:ok, image} = Image.compose(image, blowout, x: 260, y: 340)
      #=> {:ok, image} = Image.compose(image, start_saving, x: 260, y: 400)

      # Compose images over a base image
      # using a composition list and coordinates
      # that are either absolute with respect to the
      # base image or relative to the previously
      # composed image.

      #=> Image.compose(base_image, [
      ..>   {polygon, x: :center, y: :top},
      ..>   {explore_new, y_baseline: :top, x_baseline: :left, dx: 20, dy: 200},
      ..>   {places, dy: 10},
      ..>   {blowout, dy: 20},
      ..>   {start_saving, dy: 50}
      ..> ])

  """
  @doc subject: "Operation"

  @spec compose(
          base_image :: Vimage.t(),
          overlay_image :: Vimage.t(),
          options :: Options.Compose.t()
        ) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def compose(base_image, overlay_image_or_images, options \\ [])

  def compose(%Vimage{} = base_image, %Vimage{} = overlay_image, options) do
    x = Keyword.get(options, :x, :center)
    y = Keyword.get(options, :y, :middle)
    blend_mode = Keyword.get(options, :blend_mode)

    with {:ok, blend_mode} <- Image.BlendMode.validate_blend_mode(blend_mode) do
      {x, y} = xy_offset(base_image, overlay_image, x, y)
      Operation.composite2(base_image, overlay_image, blend_mode, x: x, y: y)
    end
  end

  @spec compose(
          base_image :: Vimage.t(),
          image_list :: composition_list(),
          options :: Options.Compose.t()
        ) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def compose(%Vimage{} = base_image, image_list, _options) when is_list(image_list) do
    width = Image.width(base_image)
    height = Image.height(base_image)

    zipped =
      Enum.reduce_while(image_list, {0, 0, width, height, []}, fn
        %Vimage{} = image, {prev_x, prev_y, prev_width, prev_height, acc} ->
          build_composition(image, prev_x, prev_y, prev_width, prev_height, acc, Map.new())

        {%Vimage{} = image, options}, {prev_x, prev_y, prev_width, prev_height, acc} ->
          build_composition(image, prev_x, prev_y, prev_width, prev_height, acc, Map.new(options))
      end)

    case zipped do
      {:error, reason} ->
        {:error, reason}

      {_x, _y, _height, _width, list} ->
        {overlay_images, x_list, y_list, blend_modes} = unzip_composition(list)
        Operation.composite([base_image | overlay_images], blend_modes, x: x_list, y: y_list)
    end
  end

  defp build_composition(image, prev_x, prev_y, prev_width, prev_height, acc, options) do
    import Compose, only: [get_x: 6, get_y: 6]

    options = Map.merge(Compose.default_composit_options(), options)

    with {:ok, x} <- get_x(image, prev_x, prev_width, options.x, options.dx, options.x_baseline),
         {:ok, y} <- get_y(image, prev_y, prev_height, options.y, options.dy, options.y_baseline),
         {:ok, blend_mode} <- BlendMode.validate_blend_mode(options.blend_mode) do
      {:ok, [image, x, y, blend_mode]}
    end
    |> accumulate_compositions(image, acc)
  end

  defp unzip_composition(list) do
    Enum.reduce(list, {[], [], [], []}, fn
      [image, x, y, blend_mode], {images, xs, ys, blend_modes} ->
        {[image | images], [x | xs], [y | ys], [blend_mode | blend_modes]}
    end)
  end

  defp accumulate_compositions(composition, image, acc) do
    case composition do
      {:ok, composition} ->
        [_image, x, y | _rest] = composition
        {:cont, {x, y, Image.width(image), Image.height(image), [composition | acc]}}

      {:error, reason} ->
        {:halt, reason}
    end
  end

  @doc """
  Compose two images together to form a new image or
  raise an exception.

  ### Arguments

  * `base_image` is any `t:Vix.Vips.Image.t/0`.

  * `overlay_image` is any `t:Vix.Vips.Image.t/0` that will
    be composed over the top of `base_image`.

  * `options` is a keyword list of options.

  ### Options

  * `:blend_mode` is the manner in which the two
    images are composited. See `t:Image.BlendMode.t/0`.
    The default is `:over` which is the most common blend
    mode.

  * `:x` is the offset (0-based) which, if zero or positive,
    from the *left* of the `base_image`. If negative is is
    the offset from the *right* of the `base_image`.
    where the `overlay_image` will be placed. It may also be
    one of the keywords `:left`, `:right` or `:center`. The
    default is `:center`.

  * `:y` is the offset (0-based) which, if zero or positive,
    from the *top* of the `base_image`. If negative is is
    the offset from the *bottom* of the `base_image`.
    where the `overlay_image` will be placed.  It may also be
    one of the keywords `:top`, `:bottom` or `:middle`. The
    default is `:middle`.

  ### Composition list options

  When `overlay_image` is an `image_list`, each entry in
  the list is either a `t:Vix.Vips.Image.t/0` or a
  `t:Image.composition_list/0`. A composition supports the specification
  of how a particular image is composed onto the base image.

  * `:x` describes the absolute `x` offset on the
    base image where this image will be placed. If
    this option is set to `:left`, `:center` or
    `:right` then the `x` position will be calculated
    relative to the base image. If `:x` is nil
    (the default) then the image will be placed according
    to the relative offset of the previously composed
    image using `:dx`.

  * `:y` describes the absolute `y` offset on the
    base image where this image will be placed. If
    this option is set to `:top`, `:middle` or
    `:bottom` then the `y` position will be calculated
    relative to the base image. If `:y` is nil
    (the default) then the image will be placed according
    to the relative offset of the previously composed
    image using `:dy`.

  * `:dx` describes the relative offset used to calculate
    the `x` value. `:dx` is an integer offset from the
    edge of the previously composed image. Which edge is
    determined by the `:x_baseline` option. If `:x` is also
    specified then `:x` is first calculated, then `:dx` is
    added to it. In this case, `:x_baseline` is ignored.

  * `:dy` describes the relative offset used to calculate
    the `y` value. `:dy` is an integer offset from the
    edge of the previously composed image. Which edge is
    determined by the `:y_baseline` option. If `:y` is also
    specified then `:y` is first calculated, then `:dy` is
    added to it. In this case, `:x_baseline` is ignored.

  * `:blend_mode` is the `t:Image.BlendMode.t/0` used when
    composing this image over its base image. The default
    is `:over` which is appropriate for most use cases.

  * `:x_baseline` establishes the baseline on the
    previously composed image from which `:dx` is
    calculated. The default is `:right`.

  * `:y_baseline` establishes the baseline on the
    previously composed image from which `:dy` is
    calculated. The default is `:bottom`.

  ### Returns

  * `composed_image` or

  * raises an exception

  ### Examples

      # Compose images over a base image using
      # absolute  coordinates from the base image
      # to place each overlay image
      #=> base_image
      ..> |> Image.compose!(polygon, x: :middle, y: :top)
      ..> |> Image.compose!(explore_new, x: 260, y: 200)
      ..> |> Image.compose!(places, x: 260, y: 260)
      ..> |> Image.compose!(blowout, x: 260, y: 340)
      ..> |> Image.compose!(start_saving, x: 260, y: 400)

      # Compose images over a base image
      # using a composition list and coordinates
      # that are either absolute with respect to the
      # base image or relative to the previously
      # composed image
      #=> base_image
      ..> |> Image.compose!([
      ..>   {polygon, x: :center, y: :top},
      ..>   {explore_new, y_baseline: :top, x_baseline: :left, dx: 20, dy: 200},
      ..>   {places, dy: 10},
      ..>   {blowout, dy: 20},
      ..>   {start_saving, dy: 50}
      ..> ])

  """
  @doc subject: "Operation"

  @spec compose!(
          base_image :: Vimage.t(),
          overlay_image :: Vimage.t(),
          options :: Options.Compose.t()
        ) ::
          Vimage.t() | no_return()

  def compose!(base_image, image_or_image_list, options \\ [])

  def compose!(%Vimage{} = base_image, %Vimage{} = overlay_image, options) do
    case compose(base_image, overlay_image, options) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @spec compose!(
          base_image :: Vimage.t(),
          image_list :: composition_list(),
          options :: Options.Compose.t()
        ) ::
          Vimage.t() | no_return()

  def compose!(%Vimage{} = base_image, image_list, options) when is_list(image_list) do
    case compose(base_image, image_list, options) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Create a meme image from a base image and
  one or two lines of text.

  The size of the text is determined by the size
  of the base image.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0` over which
    the meme text will be composed.

  * `headline` is the top line of the meme text.

  * `options` is a keyword list of options.

  ### Options

  * `:text` is the second line of text at the bottom of the
    meme image. The default is `""`.

  * `:text_size` is the size of the bottom text in points.
    The default is calculated proportional to the size of the
    image.

  * `:headline_size` is the size of the headline text in points.
    The default is calculated proportional to the size of the
    image.

  * `:font` is the name of the font family to be applied.
    The default is `Impact`.

  * `:font_file` is the path name to a font file that will be
    loaded. The default is `:default` which will load the included
    `Impact` font if the font family is `Impact`. If the font family
    is not `Impact` and the `:font_file` is `:default` then the
    font displayed is resolved by the underlying operating system.
    If `:font_file` is a string, then it is expected to be a valid
    font file. If `:font_file` is set to a path then the `:font` option
    should also be set to the correct font name.

  * `:weight` is the font weight to be rendered. The options
    are `:ultralight`, `:light`, `:normal`, `:bold`, `:ultrabold`,
    and `:heavy`. The default `:bold`.

  * `:transform` determines how the text is presented. The
    options are `:upcase`, `:downcase`, `:capitalize` and `:none`.
    The default is `:upcase`.

  * `:color` is an RGB color of the text. The color can be an
    integer between `0..255`, a three-element list of
    integers representing an RGB color or an atom
    representing a CSS color name. The default is `:white`.

  * `:outline_color` is an RGB color of the text outline. The
    color can be an integer between `0..255`, a three-element list of
    integers representing an RGB color or an atom
    representing a CSS color name. The default is `:black`.

  * `:margin` is the width of the margin in pixels. The margin is
    applied to both the left and right sides of the image. The
    default is calculated proportional to the size of the
    image.

  """
  @doc subject: "Generator", since: "0.13.0"

  @spec meme(image :: Vimage.t(), headline :: String.t(), options :: Options.Meme.meme_options()) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def meme(%Vimage{} = image, headline, options \\ []) when is_binary(headline) do
    with {:ok, options} <- Options.Meme.validate_options(image, options),
         {:ok, width} <- text_box_width(image, options),
         {:ok, headline} <- text_overlay(headline, options.headline_size, width, options),
         {:ok, text} <- text_overlay(options.text, options.text_size, width, options) do
      image
      |> compose!(headline, headline_location(image, headline))
      |> compose(text, text_location(image, text))
    end
  end

  @doc """
  Return a meme image from a base image and
  one or two lines of text or raise an exception.

  The size of the text is determined by the size
  of the base image.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0` over which
    the meme text will be composed.

  * `headline` is the top line of the meme text.

  * `options` is a keyword list of options.

  ### Options

  * `:text` is the second line of text at the bottom of the
    meme image. The default is `""`.

  * `:text_size` is the size of the bottom text in points.
    The default is calculated proportional to the size of the
    image.

  * `:headline_size` is the size of the headline text in points.
    The default is calculated proportional to the size of the
    image.

  * `:font` is the name of the font family to be applied.
    The default is `Impact`. If the font family name is `"Impact"`
    then the included `unicode.impact.ttf` font file will also be
    loaded. This ensures that the `Impact` font is available on all
    systems.

  * `:font_file` is the path name to a font file that will be
    loaded. The default is `:default` which will load the included
    `Impact` font if the font family is `Impact`. If the font family
    is not `Impact` and the `:font_file` is `:default` then the
    font displayed is resolved by the underlying operating system.
    If `:font_file` is a string, then it is expected to be a valid
    font file. If `:font_file` is set to a path then the `:font` option
    should also be set to the correct font name.

  * `:weight` is the font weight to be rendered. The options
    are `:ultralight`, `:light`, `:normal`, `:bold`, `:ultrabold`,
    and `:heavy`. The default `:bold`.

  * `:justify` is a boolean indicating if the headline and text
    are to be justified. If `true` then space is added between
    words so that both edges of each line are aligned with both
    margins. The default is `false`.

  * `:transform` determines how the text is presented. The
    options are `:upcase`, `:downcase`, `:capitalize` and `:none`.
    The default is `:upcase`.

  * `:color` is an RGB color of the text. The color can be an
    integer between `0..255`, a three-element list of
    integers representing an RGB color or an atom
    representing a CSS color name. The default is `:white`.

  * `:outline_color` is an RGB color of the text outline. The
    color can be an integer between `0..255`, a three-element list of
    integers representing an RGB color or an atom
    representing a CSS color name. The default is `:black`.

  * `:margin` is the width of the margin in pixels. The margin is
    applied to both the left and right sides of the image. The
    default is calculated proportional to the size of the
    image.

  """
  @doc subject: "Generator", since: "0.13.0"

  @spec meme!(image :: Vimage.t(), headline :: String.t(), options :: Options.Meme.meme_options()) ::
          Vimage.t() | no_return()

  def meme!(%Vimage{} = image, headline, options \\ []) when is_binary(headline) do
    case meme(image, headline, options) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  defp text_box_width(image, %{margin: margin}) do
    {:ok, width(image) - 2 * margin}
  end

  defp text_overlay("", _size, _width, _options) do
    Operation.black(1, 1)
  end

  defp text_overlay(text, size, width, %{font: font} = options) do
    text = "<b>" <> transform(text, options.transform) <> "</b>"
    font = "#{font} #{size}"

    text_options =
      [font: font, width: width, align: :VIPS_ALIGN_CENTRE]
      |> maybe_add_fontfile(options[:fontfile])

    with {:ok, {text, _}} <- Operation.text(text, text_options) do
      outline(text, options)
    end
  end

  @doc false
  def maybe_add_fontfile(options, nil) do
    options
  end

  def maybe_add_fontfile(options, font_file) do
    Keyword.put(options, :fontfile, font_file)
  end

  defp outline(image, %{color: color, outline_color: outline_color} = options) do
    radius = round(options.headline_size / 10)
    width = width(image) + 2 * radius
    height = height(image) + 2 * radius

    {:ok, text} = Operation.embed(image, radius, radius, width, height)

    {:ok, circle_mask} =
      Operation.black!(radius * 2 + 1, radius * 2 + 1)
      |> Math.add!(128)
      |> Draw.circle(radius, radius, radius, fill: true, color: :white)

    {:ok, outlined} =
      text
      |> Operation.morph!(circle_mask, :VIPS_OPERATION_MORPHOLOGY_DILATE)
      |> blur(sigma: 0.5, min_amplitude: 0.1)

    {:ok, background_text} =
      outlined
      |> new!(color: outline_color, bands: 3)
      |> bandjoin!(outlined)
      |> Operation.copy(interpretation: :VIPS_INTERPRETATION_sRGB)

    {:ok, foreground_text} =
      text
      |> new!(color: color, bands: 3)
      |> bandjoin!(text)
      |> Operation.copy(interpretation: :VIPS_INTERPRETATION_sRGB)

    compose(background_text, foreground_text)
  end

  defp transform(text, :none), do: text
  defp transform(text, :capitalize), do: String.capitalize(text)
  defp transform(text, :upcase), do: String.upcase(text)
  defp transform(text, :downcase), do: String.downcase(text)

  # defp bandjoin(a, nil), do: {:ok, a}
  defp bandjoin(a, b), do: Operation.bandjoin([a, b])

  defp bandjoin!(a, nil), do: a
  defp bandjoin!(a, b), do: Operation.bandjoin!([a, b])

  @headline_distance_from_top 0.03
  @text_distance_from_bottom 0.03

  defp headline_location(image, text) do
    x = ((width(image) - width(text)) / 2) |> round()
    y = (height(image) * @headline_distance_from_top) |> round()
    [x: x, y: y]
  end

  defp text_location(image, text) do
    x = ((width(image) - width(text)) / 2) |> round()
    y = (height(image) - height(text) - height(image) * @text_distance_from_bottom) |> round()
    [x: x, y: y]
  end

  @doc """
  Returns the filename for an image.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * The pathname from which the image was opened or
    `nil` if there is no associated path. This can
    happen in the case of a streamed image or an image
    created from a memory buffer.

  """
  @doc subject: "Image info"

  @spec filename(image :: Vimage.t()) :: Path.t() | nil
  def filename(%Vimage{} = image) do
    Vix.Vips.Image.filename(image)
  rescue
    e in RuntimeError ->
      if e.message == "null_value" do
        nil
      else
        reraise e, __STACKTRACE__
      end
  end

  @doc """
  Returns the EXIF data for an image as a
  map.

  Only a subset of EXIF data is returned but
  its a substantial subset.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`

  ### Returns

  * `{:ok, exif_map}` where `exif_map` is a map
    of selected EXIF data.

  * `{:error, reason}`

  """
  @doc subject: "Metadata"

  @spec exif(Vimage.t()) :: {:ok, map()} | {:error, error_message()}
  def exif(%Vimage{} = image) do
    with {:ok, exif_blob} <- Vimage.header_value(image, "exif-data"),
         <<"Exif"::binary, 0::16, exif::binary>> <- exif_blob do
      exif
      |> Exif.extract_exif()
      |> wrap(:ok)
    else
      false -> {:error, "Invalid Exif data"}
      other -> other
    end
  end

  @doc """
  Returns the XMP data for an image as a
  keyword list.

  Only a selected set of XMP data is returned.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`

  ### Returns

  * `{:ok, xmp_map}` where `xmp_map` is a map
    of selected XMP data.

  """
  @doc subject: "Metadata"

  @spec xmp(Vimage.t()) :: {:ok, map()}
  def xmp(%Vimage{} = image) do
    with {:ok, xmp_blob} <- Vimage.header_value_as_string(image, "xmp-data"),
         {:ok, xmp_binary} <- Base.decode64(xmp_blob) do
      xmp_binary
      |> SweetXml.parse(dtd: :none)
      |> Xmp.extract_xmp()
      |> wrap(:ok)
    end
  end

  @doc """
  Returns the width of an image.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * The image width as an integer.

  """
  @doc subject: "Image info"

  @spec width(image :: Vimage.t()) :: pos_integer()
  def width(%Vimage{} = image) do
    Vimage.width(image)
  end

  @doc """
  Returns the height of an image.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * The image height as an integer.

  """
  @doc subject: "Image info"

  @spec height(image :: Vimage.t()) :: pos_integer()
  def height(%Vimage{} = image) do
    Vimage.height(image)
  end

  @doc """
  Returns the band format of an image.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * The band format of the image in `Nx` notation.

  ### Examples

        iex> image = Image.open!("./test/support/images/Singapore-2016-09-5887.jpg")
        iex> Image.band_format(image)
        {:u, 8}

  """
  @doc subject: "Image info"
  @doc since: "0.35.0"

  @spec band_format(image :: Vimage.t()) :: Image.BandFormat.t()
  def band_format(%Vimage{} = image) do
    image
    |> Vix.Vips.Image.format()
    |> Image.BandFormat.nx_format!()
  end

  @doc """
  Returns the range of permissable values
  as a tuple for each pixel in an image.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * `{min_value, max_value}` where `min_value` and
    `max_value` are integers for unsigned images and
    floats for signed images.

  ### Examples

        iex> image = Image.open!("./test/support/images/Singapore-2016-09-5887.jpg")
        iex> Image.range(image)
        {0, 255}

  """
  @doc since: "0.35.0"
  @doc subject: "Image info"

  @spec range(image :: Vimage.t()) :: {non_neg_integer() | float(), non_neg_integer() | float()}
  def range(%Vimage{} = image) do
    case band_format(image) do
      {:u, bits} -> {0, 2 ** bits - 1}
      {:s, bits} -> {-1.0 * 2 ** (bits - 1), 2 ** (bits - 1) - 1.0}
    end
  end

  @doc """
  Return the number of bands in an image.

  A band is sometimes referred to as a
  channel.

  Note than bands are 0-indexed. That is, the
  first band is band 0, the second band is
  band 1 and so on.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * An integer number of bands in the image.

  """
  @doc subject: "Image info"

  @spec bands(image :: Vimage.t()) :: pos_integer()
  def bands(%Vimage{} = image) do
    Vimage.bands(image)
  end

  @doc """
  Returns the number of pages in an image.

  Animated images will return an integer representing
  the number of animated frames. Normal images will
  return `1`.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * `integer` number of pages in the `image`.

  ### Example

      iex> image = Image.open!("./test/support/images/animated.webp")
      iex> Image.pages(image)
      12

      iex> image = Image.open!("./test/support/images/Kamchatka-2019-8754.jpg")
      iex> Image.pages(image)
      1

  """
  @doc subject: "Image info", since: "0.38.0"

  @spec pages(image :: Vimage.t()) :: pos_integer()
  def pages(%Vimage{} = image) do
    case Vix.Vips.Image.header_value(image, "n-pages") do
      {:ok, pages} -> pages
      {:error, _reason} -> 1
    end
  end

  @doc """
  Returns the shape of an image.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * The image shape as a tuple of
    `{width, height, bands}`.

  ### Example

      iex> image = Image.open!("./test/support/images/Kamchatka-2019-8754.jpg")
      iex> Image.shape(image)
      {1000,542, 3}

  """
  @doc subject: "Image info", since: "0.9.0"

  @spec shape(image :: Vimage.t() | MutableImage.t()) ::
          {width :: pos_integer(), height :: pos_integer(), bands :: pos_integer()}

  def shape(%image_type{} = image) when is_image(image_type) do
    {width(image), height(image), bands(image)}
  end

  @doc """
  Returns the image interpretation.

  The interpretation is how `Image` understands
  the image date. For example, `:srgb`, `:cmyk` or
  `:bw`.

  For most common web applications, the
  interpretation will be `:srgb`.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`

  ### Returns

  * The image interpretation as an atom.

  ### Notes

  * See also `Image.Interpretation.known_interpretations/0`

  ### Example

      iex> image = Image.open!("./test/support/images/Kamchatka-2019-8754.jpg")
      iex> Image.interpretation(image)
      :srgb

  """
  @doc subject: "Image info", since: "0.9.0"

  @spec interpretation(image :: Vimage.t()) :: Image.Interpretation.t()
  def interpretation(%Vimage{} = image) do
    image
    |> Vix.Vips.Image.interpretation()
    |> Image.Interpretation.decode_interpretation()
  end

  @doc """
  Returns the data type of the image pixels.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`

  ### Returns

  * The image type as a tuple in the same
    format as `t:Nx.Type.t/0`. For example
    `{:u, 8}` for a common `:srgb` image.

  ### Example

      iex> image = Image.open!("./test/support/images/Kamchatka-2019-8754.jpg")
      iex> Image.type(image)
      {:ok, {:u, 8}}

  """
  @dialyzer {:nowarn_function, {:type, 1}}

  @doc subject: "Image info", since: "0.9.0"

  @spec type(image :: Vimage.t()) :: Image.BandFormat.t()
  def type(%Vimage{} = image) do
    Image.BandFormat.nx_format(image)
  end

  @doc """
  Flip an image horizontally or vertically.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `direction` is either `:horizontal` or
    `:vertical`.

  ### Returns

  * `{:ok, flipped_image}` or

  * `{:error, reason}`

  """
  @doc subject: "Operation"

  @spec flip(image :: Vimage.t(), direction :: :vertical | :horizontal) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def flip(%Vimage{} = image, :vertical) do
    Operation.flip(image, :VIPS_DIRECTION_VERTICAL)
  end

  def flip(%Vimage{} = image, :horizontal) do
    Operation.flip(image, :VIPS_DIRECTION_HORIZONTAL)
  end

  def flip(%Vimage{} = _image, direction) do
    {:error,
     "Invalid flip direction. Must be :vertical or :horizontal.  Found #{inspect(direction)}"}
  end

  @doc """
  Flip an image horizontally or vertically returning
  a flipped image or raising an exception.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `direction` is either `:horizontal` or
    `:vertical`.

  ### Returns

  * `flipped_image` or

  * raises an exception.

  """
  @doc subject: "Operation"

  @spec flip!(image :: Vimage.t(), direction :: :vertical | :horizontal) ::
          Vimage.t() | no_return()

  def flip!(%Vimage{} = image, direction) do
    case flip(image, direction) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Resize an image.

  If the intent is to thumbnail an image then `Image.thumbnail/3`
  is recommended since it applies a very efficient downsizing
  algorithm for that use case.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `scale` is a float scale factor.

  * `options` is a keyword list of options.

  ### Options

  * `:centre` is a boolean indicating whether to use
    the centre downsampling convention. The default is
    `false`.

  * `:interpolate` defines which resampling kernel to apply.
    The options are `:nearest`, `:linear`, `:cubic`,
    `:mitchell`, `:lanczos2` or `:lanczos3` (the default).

  ### Returns

  * `{:ok, resized_image}` or

  * raises an exception

  """

  @doc subject: "Resize", since: "0.13.0"

  @spec resize(Vimage.t(), scale :: number(), options :: Resize.resize_options()) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def resize(%Vimage{} = image, scale, options \\ []) when scale >= 0 do
    with {:ok, options} <- Resize.validate_options(options) do
      do_resize(image, scale, options, has_alpha?(image))
    end
  end

  @dialyzer {:nowarn_function, {:do_resize, 4}}

  defp do_resize(image, scale, options, false = _has_alpha?) do
    Operation.resize(image, scale, options)
  end

  defp do_resize(image, scale, options, true = _has_alpha?) do
    band_format = Vix.Vips.Image.format(image)
    premultiplied = Operation.premultiply!(image)

    with {:ok, resized} <- Operation.resize(premultiplied, scale, options) do
      resized
      |> Operation.unpremultiply!()
      |> Operation.cast(band_format)
    end
  end

  @doc """
  Resize an image or raise an exception.

  If the intent is to thumbnail an image then `Image.thumbnail/3`
  is recommended since it applies a very efficient downsizing
  algorithm for that use case.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `scale` is a float scale factor.

  * `options` is a keyword list of options.

  ### Options

  * `:centre` is a boolean indicating whether to use
    the centre downsampling convention. The default is
    `false`.

  * `:interpolate` defines which resampling kernel to apply.
    The options are `:nearest`, `:linear`, `:cubic`,
    `:mitchell`, `:lanczos2` or `:lanczos3` (the default).

  ### Returns

  * `resized_image` or

  * raises an exception

  """

  @doc subject: "Resize", since: "0.14.0"

  @spec resize!(Vimage.t(), scale :: number(), options :: Resize.resize_options()) ::
          Vimage.t() | no_return()

  def resize!(%Vimage{} = image, scale, options \\ []) when scale >= 0 do
    case resize(image, scale, options) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Pixelates an image.

  Pixelation is the process of reducing the image
  resolution while retaining the image dimensions.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `scale` is the scale factor to apply to
    the image when it is pixelated. This means that
    one "pixel" is `image width * scale`. The default
    is `#{@pixelate_scale}`.

  ### Returns

  * `{:ok, pixelated_image}` or

  * `{:error, reason}`

  """
  @doc subject: "Operation", since: "0.14.0"

  @spec pixelate(image :: Vimage.t(), scale :: number()) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def pixelate(%Vimage{} = image, scale \\ @pixelate_scale) when is_number(scale) and scale > 0 do
    image
    |> resize!(scale)
    |> resize(1 / scale, interpolate: :nearest)
  end

  @doc """
  Pixelates an image or raise an exception.

  Pixelation is the process of reducing the image
  resolution while retaining the image dimensions.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `scale` is the scale factor to apply to
    the image when it is pixelated. This means that
    one "pixel" is `image width * scale`. The default
    is `#{@pixelate_scale}`.

  ### Returns

  * `{:ok, pixelated_image}` or

  * `{:error, reason}`

  """
  @doc subject: "Operation", since: "0.14.0"

  @spec pixelate!(image :: Vimage.t(), scale :: number()) ::
          Vimage.t() | no_return()

  def pixelate!(%Vimage{} = image, scale \\ @pixelate_scale)
      when is_number(scale) and scale > 0 do
    case pixelate(image, scale) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Thumbnail an image to fit or fill a bounding box.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0` or a
    pathname to an image file.

  * `length` is the integer length of the longest
    side of the resulting image after resizing. It can
    also be of the form "<width>x<height>". That
    is, a string with the width and height separated
    by an `x`. The `<height>` may be omitted in which
    case it is the same as providing an integer length.

  * `options` is a keyword list of options.

  ### Options

  * `:crop` determines if the strategy is "resize to fit"
    (crop is `:none`) or "resize to fill" (when the crop
    option is not `:none`). The value may be one of
    `:none`, `:center`, `:entropy`, `:attention`, `:low`
    or `:high`. The default is `:none`. See also `t:Image.Options.Crop.crop_focus/0`.

  * `:height` - Size to this height. Default is to maintain
    the image aspect ratio unless `resize: :force` is set. If
    `resize; :force` is set then the default `:height` is the
    height of `image`.

  * `:fit` sets the `:crop` and `:resize` options to align
    with the CSS [object-fit](https://www.w3schools.com/css/css3_object-fit.asp)
    property. Note that using the `:fit` option overwrites the
    options `:crop` and `:resize`. Since options are processed in
    the order in which they are presented, `:crop` and `:resize`
    may still be force set if they are after the `:fit` option.
    `:fit` takes one of the following values:

    * `:fill` - the image is resized to fill the given dimension.
      If necessary, the image will be stretched or squished to fit.
      This is the same as setting `resize: :force`. Note that is
      `:height` is not specified it will be the same height as `image`.

    * `:contain` - the image keeps its aspect ratio, but is resized
      to fit within the given dimension. This is the same as
      setting `crop: :none` and `resize: :both`.

    * `:cover` - the image keeps its aspect ratio and fills the given
      dimensions. The image will be clipped to fit. Clipping will default to
      `:center` unless `:crop` is already set to a value other
      than `:none`. This is the same as setting `crop: :center`
      (if `:crop` is not already set) and `resize: :both`.

  * `:autorotate` is a boolean indicating if the image should
    be autorotated based upon the image metadata. The default
    is `true`.

  * `:intent` indicates the rendering intent. The default
    is `:relative`. See also `t:Image.render_intent/0`.

  * `:export_icc_profile` indicates the icc profile to be attached
    to the resized image. The value may be an inbuilt profile (`:srgb`,
    `:p3` or `:cmyk`), the name of an icc profile in the systems
    profile directory or a full path to an icc profile file. The
    default is to export the icc profile of the resized image if
    there is one.

  * `:import_icc_profile` indicates the icc profile to be attached
    to the input image. The value may be an inbuilt profile (`:srgb`,
    `:p3` or `:cmyk`), the name of an icc profile in the systems
    profile directory or a full path to an icc profile file. The
    default is to use the icc profile of the input image if
    there is one.

  * `:linear` is a boolean indicating of the image should
    be resized in linear space. The default `false`. Shrinking is
    normally done in sRGB colourspace. Set linear to shrink in
    linear light colourspace instead. This can give better results,
    but can also be far slower, since tricks like JPEG shrink-on-load
    cannot be used in linear space.

  * `:resize` determines if an image may be only upsized, only
    downsized, both or a forced aspect ratio is applied. The value
    may be one of `:up`, `:down`, `:both` or `:force`. The default
    is `:both`.

  ### Returns

  * `{:ok, thumbnailed_image}` or

  * `{:error, reason}`

  """
  @doc subject: "Resize"

  @spec thumbnail(Vimage.t(), length :: pos_integer(), options :: Thumbnail.thumbnail_options()) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def thumbnail(image_or_path, length, options \\ [])

  def thumbnail(%Vimage{} = image, length, options) when is_size(length) do
    with {:ok, options} <- Thumbnail.validate_options(options) do
      Operation.thumbnail_image(image, length, options)
    end
  end

  @spec thumbnail(Path.t(), length :: pos_integer(), options :: Thumbnail.thumbnail_options()) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def thumbnail(image_path, length, options) when is_binary(image_path) and is_size(length) do
    with {:ok, options} <- Thumbnail.validate_options(options),
         {:ok, _path} <- file_exists?(image_path) do
      Operation.thumbnail(image_path, length, options)
    else
      {:error, _reason} = error -> error
    end
  end

  @spec thumbnail(
          Vimage.t() | Path.t(),
          dimensions :: binary(),
          options :: Thumbnail.thumbnail_options()
        ) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def thumbnail(image_or_path, dimensions, options) when is_binary(dimensions) do
    with {:ok, length, options} <- Thumbnail.validate_dimensions(dimensions, options) do
      thumbnail(image_or_path, length, options)
    end
  end

  @doc """
  Thumbnail an image to fit or fill a bounding box
  returning an image or raising an exception.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0` or a
    pathname to an image file.

  * `length` is the integer length of the longest
    side of the resulting image after resizing. It c
    an also be of the form "<width>x<height>". That
    is, a string with the width and height separated
    by an `x`. The `<height>` may be omitted in which
    case it is the same as providing an integer length.

  * `options` is a keyword list of options.
    See `Image.thumbnail/3`.

  ### Returns

  * `image` or

  * raises an exception.

  """
  @doc subject: "Resize"

  @spec thumbnail!(Vimage.t(), length :: pos_integer(), options :: Thumbnail.thumbnail_options()) ::
          Vimage.t() | no_return()

  def thumbnail!(image_or_path, length, options \\ [])

  def thumbnail!(%Vimage{} = image, length_or_dimensions, options) do
    case thumbnail(image, length_or_dimensions, options) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @spec thumbnail!(Path.t(), length :: pos_integer(), options :: Thumbnail.thumbnail_options()) ::
          Vimage.t() | no_return()

  def thumbnail!(image_path, length, options) when is_binary(image_path) and is_size(length) do
    with {:ok, options} <- Thumbnail.validate_options(options),
         {:ok, _path} <- file_exists?(image_path) do
      Operation.thumbnail!(image_path, length, options)
    else
      {:error, :enoent} -> raise Image.Error, {:enoent, image_path}
    end
  end

  @spec thumbnail!(
          Vimage.t() | Path.t(),
          dimensions :: binary(),
          options :: Thumbnail.thumbnail_options()
        ) ::
          Vimage.t() | no_return()

  def thumbnail!(image_or_path, dimensions, options) when is_binary(dimensions) do
    with {:ok, length, options} <- Thumbnail.validate_dimensions(dimensions, options) do
      thumbnail!(image_or_path, length, options)
    end
  end

  @doc """
  Make a circular, squircular or square image intended to be used
  as an avatar image.

  The image is resized and all metadata is removed
  from the image. The image will be cropped to a square
  shape and then depending on the `:shape` option
  a circular or squirclar mask may be applied.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `options` is a keyword list of options. The
    default is `[shape: :circle, crop: :none, size: #{Image.Options.Avatar.default_avatar_size()}]`.

  ### Options

  * `:size` is the diameter (in the case of `shape: :circle`
    or `shape; :squircle`. It is the width/height in the case
    of `shape: :square` of the resulting image after resizing.
    The default value is `#{Image.Options.Avatar.default_avatar_size()}`.

  * `:shape` defines shape of the avatar
    which can be either `:circle` (the default), `:squircle`
    or `:square`.  In each case the image is first
    center cropped to a square shape. Then if the
    format is `:circle` or `:squircle` an appropriate image
    mask is applied.

  * `:crop_focus` is one of `:none`, `:center`, `:entropy`,
    `:attention`, `:low`, `:high`. The default is `:none`.
    For details see `t:Image.Options.Crop.crop_focus/0`.

  ### Returns

  * `{:ok, avatar_image}` or

  * `{:error, reason}`

  """
  @doc subject: "Generator"

  @spec avatar(Vimage.t(), options :: Options.Avatar.avatar_options()) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def avatar(image, options \\ [])

  def avatar(%Vimage{} = image, options) do
    with {:ok, options} <- Options.Avatar.validate_options(options),
         {:ok, image} <- thumbnail(image, options[:size], thumbnail_options(options)),
         {:ok, flattened} <- flatten(image) do
      do_avatar(flattened, options[:shape])
    end
  end

  def avatar(image_path, options) when is_binary(image_path) do
    with {:ok, options} <- Options.Avatar.validate_options(options),
         {:ok, image_path} = file_exists?(image_path),
         {:ok, image} = thumbnail(image_path, options[:size], thumbnail_options(options)),
         {:ok, flattened} = flatten(image) do
      do_avatar(flattened, options[:shape])
    end
  end

  @doc """
  Make a circular, squircular or square image intended to be used
  as an avatar image or raise an exception.

  The image is resized and all metadata is removed
  from the image. The image will be cropped to a square
  shape and then depending on the `:shape` option
  a circular or squirclar mask may be applied.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `options` is a keyword list of options. The
    default is `[shape: :circle, crop: :none, size: #{Image.Options.Avatar.default_avatar_size()}]`.

  ### Options

  * `:size` is the diameter (in the case of `shape: :circle`
    or `shape; :squircle`. It is the width/height in the case
    of `shape: :square` of the resulting image after resizing.
    The default value is `#{Image.Options.Avatar.default_avatar_size()}`.

  * `:shape` defines shape of the avatar
    which can be either `:circle` (the default), `:squircle`
    or `:square`.  In each case the image is first
    cropped to a square shape. Then if the
    format is `:circle` or `:squircle` an appropriate image
    mask is applied.

  * `:crop_focus` is one of `:none`, `:center`, `:entropy`,
    `:attention`, `:low`, `:high`. The default is `:none`.
    For details see `t:Image.Options.Crop.crop_focus/0`.

  ### Returns

  * `avatar_image` or

  * raises an exception.

  """
  @doc subject: "Generator"

  @spec avatar!(Vimage.t(), options :: Options.Avatar.avatar_options()) ::
          Vimage.t() | no_return()

  def avatar!(image, options \\ []) do
    case avatar(image, options) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  defp do_avatar(image, :square) do
    square(image)
  end

  defp do_avatar(image, :squircle) do
    {:ok, image} = square(image)
    {:ok, image} = squircle(image)
    remove_metadata(image)
  end

  defp do_avatar(image, :circle) do
    {:ok, squared} = square(image)
    circular_mask_and_remove_meta(squared)
  end

  defp square(image) do
    {width, height, _bands} = Image.shape(image)

    if width > height do
      x = round((width - height) / 2)
      y = 0
      crop(image, x, y, height, height)
    else
      x = 0
      y = round((height - width) / 2)
      crop(image, x, y, width, width)
    end
  end

  defp circular_mask_and_remove_meta(image) do
    {:ok, image} = circle(image)
    remove_metadata(image)
  end

  defp thumbnail_options(options) do
    options
    |> Keyword.delete(:crop)
    |> Keyword.delete(:shape)
    |> Keyword.delete(:size)
  end

  @doc """
  Crop an image.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `left` is the top edge of crop area as an
    integer or a float in the range `-1.0..1.0`.
    If `left` is an integer it is the absolute number
    of pixels. If `left` is a float it's a fraction of the width
    of the image. If `left` is positive it is relative to
    the left edge of the image. If it's negative it's
    relative to the right edge of the image. `left` may
    also be one of `:left`, `:center` and `:right`
    indicating the crop is relative to the left, center
    or right of the image.

  * `top` is the top edge of crop area as an
    integer or a float in the range `-1.0..1.0`.
    If `top` is an integer it is the absolute number of
    pixels. If `top` is a float it's a fraction of the height
    of the image. If `top` is positive it is relative to
    the top edge of the image. If it's negative it's
    relative to the bottom edge of the image. `top` may
    also be one of `:top`, `:middle` and `:bottom`
    indicating the crop is relative to the top, middle
    or bottom of the image.

  * `width` is the width of area remaining as a
    positive integer or float in the range `0.0..1.0`.
    If `width` is an integer it is the absolute number
    of pixels. If `width` is a float it's the fraction
    of the original image width.

  * `height` is the width of area remaining as a
    positive integer or float in the range `0.0..1.0`.
    If `height` is an integer it's the absolute number
    of pixels. If `height` is a float it's the fraction
    of the original image height.

  ### Notes

  * `left` is 0-indexed. That is, the leftmost
    edge of the image starts at `0`.

  * `top` is 0-indexed. That is, the topmost
    edge of the image starts at `0`.

  * If the image has multiple pages, like an animated
    `.gif` or `.webp` then each page is extracted,
    cropped and then the image reassembled.

  ### Returns

  * `{:ok, cropped_image}` or

  * `{:error, reason}`

  """

  # The shenanigans below is to avoid infinite recursion or
  # hard-to-explain errors if `Image.map_pages/2` is called with
  # `Image.crop/5` as its function argument.

  @doc subject: "Crop"

  @spec crop(Vimage.t(), x_location(), y_location(), pos_integer(), pos_integer()) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def crop(%Vimage{} = image, left, top, width, height) do
    total_height = height(image)
    dims = {width(image), total_height}

    with {left, top, width, height} <- Options.Crop.normalize_box(dims, left, top, width, height) do
      case page_height(image) do
        {:ok, page_height} ->
          if total_height == page_height do
            Operation.extract_area(image, left, top, width, height)
          else
            pages = pages(image)
            map_pages(image, &Operation.extract_area(&1, left, top, width, height), pages)
          end

        {:error, _} ->
          Operation.extract_area(image, left, top, width, height)
      end
    end
  end

  @doc """
  Crop an image.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `quadrilateral` is a list of four 2-tuples
    representing the points of the bounding rectangle. The
    points must be ordered as `[top_left, top_right, bottom_right, bottom_left]`
    Each point is of the form `{x, y}` where `x` is the
    0-based offset from the left of the image and `y` is
    the 0-based offset from the top of the image.

  ### Returns

  * `{:ok, cropped_image}` or

  * `{:error, reason}`

  ### Note

  The bounding box must be a rectangle, not an
  arbitrary quadrilateral. If required, use `Image.warp_perspective/4`
  prior to cropping.

  """
  @doc subject: "Crop", since: "0.28.0"

  @spec crop(Vimage.t(), quadrilateral()) :: {:ok, Vimage.t()} | {:error, error_message()}
  def crop(%Vimage{} = image, [top_left, top_right, bottom_right, bottom_left] = quadrilateral)
      when is_rectangle(top_left, top_right, bottom_right, bottom_left) do
    [{left, top}, _, {bottom_right_x, bottom_right_y}, _] = quadrilateral
    width = bottom_right_x - left + 1
    height = bottom_right_y - top + 1
    crop(image, left, top, width, height)
  end

  def crop(%Vimage{} = _image, quadrilateral) do
    {:error, "Invalid crop bounding box. Found #{inspect(quadrilateral)}"}
  end

  @doc """
  Crop an image or raises an exception.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `quadrilateral` is a list of four 2-tuples
    representing the points of the bounding rectangle. The
    points must be ordered as `[top_left, top_right, bottom_right, bottom_left]`
    Each point is of the form `{x, y}` where `x` is the
    0-based offset from the left of the image and `y` is
    the 0-based offset from the top of the image.

  ### Returns

  * `cropped_image` or

  * raises an exception.

  ### Note

  The bounding box must be a rectangle, not an
  arbitrary quadrilateral. If required, use `Image.warp_perspective/4`
  prior to cropping.

  """
  @doc subject: "Crop", since: "0.28.0"

  @spec crop!(Vimage.t(), quadrilateral()) :: Vimage.t() | no_return()
  def crop!(%Vimage{} = image, quadrilateral) do
    case crop(image, quadrilateral) do
      {:ok, cropped} -> cropped
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Crop an image returning a cropped image
  or raising an exception.

  ### Arguments

  * `left` is the top edge of crop area as an
    integer or a float in the range `-1.0..1.0`.
    If `left` is an integer it is the absolute number
    of pixels. If `left` a float is fraction of the width
    of the image. If `left` is positive it is relative to
    the left edge of the image. If it is negative it is
    relative to the right edge of the image. `left` may
    also be one of `:left`, `:center` and `:right`
    indicating the crop is relative to the left, center
    or right of the image.

  * `top` is the top edge of crop area as an
    integer or a float in the range `-1.0..1.0`.
    If `top` is an integer it is the absolute number of
    pixels. If `top` is a float is fraction of the height
    of the image. If `top` is positive it is relative to
    the top edge of the image. If it is negative it is
    relative to the bottom edge of the image. `top` may
    also be one of `:top`, `:middle` and `:bottom`
    indicating the crop is relative to the top, middle
    or bottom of the image.

  * `width` is the width of area remaining as a
    positive integer or float in the range `0.0..1.0`.
    If `width` is an integer it is the absolute number
    of pixels. If `width` is a float it is the fraction
    of the original image width.

  * `height` is the width of area remaining as a
    positive integer or float in the range `0.0..1.0`.
    If `height` is an integer it is the absolute number
    of pixels. If `height` is a float it is the fraction
    of the original image height.

  ### Returns

  * `cropped_image` or

  * raises an exception.

  """
  @doc subject: "Crop"

  @spec crop!(Vimage.t(), integer(), integer(), pos_integer(), pos_integer()) ::
          Vimage.t() | no_return

  def crop!(%Vimage{} = image, left, top, width, height) do
    case crop(image, left, top, width, height) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Crops the center from an image.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `width` is the width of area remaining as a
    positive integer or float in the range `0.0..1.0`.
    If `width` is an integer it is the absolute number
    of pixels. If `width` is a float it is the fraction
    of the original image width.

  * `height` is the width of area remaining as a
    positive integer or float in the range `0.0..1.0`.
    If `height` is an integer it is the absolute number
    of pixels. If `height` is a float it is the fraction
    of the original image height.

  ### Notes

  * An error will be returned if `width` and `height` are
    not equal to or smaller than the `image` dimensions.

  * This function is a convenience function equivalent to
    calling `Image.crop(image, :center, :middle, width, height)`.

  ### Returns

  * `{:ok, cropped_image}` or

  * `{:error, reason}`.

  """
  @doc subject: "Crop", since: "0.27.0"

  @spec center_crop(Vimage.t(), pos_integer(), pos_integer()) ::
          {:ok, Vimage.t()} | {:error, error_message}

  def center_crop(%Vimage{} = image, width, height) do
    crop(image, :center, :middle, width, height)
  end

  @doc """
  Crops the center from an image.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `width` is the width of area remaining as a
    positive integer or float in the range `0.0..1.0`.
    If `width` is an integer it is the absolute number
    of pixels. If `width` is a float it is the fraction
    of the original image width.

  * `height` is the width of area remaining as a
    positive integer or float in the range `0.0..1.0`.
    If `height` is an integer it is the absolute number

    of pixels. If `height` is a float it is the fraction
    of the original image height.

  ### Notes

  * An error will be returned if `width` and `height` are
    not equal to or smaller than the `image` dimensions.

  * This function is a convenience function equivalent to
    calling `Image.crop!(image, :center, :middle, width, height)`.

  ### Returns

  * `cropped_image` or

  * raises an exception.

  """
  @doc subject: "Crop", since: "0.27.0"

  @spec center_crop!(Vimage.t(), pos_integer(), pos_integer()) ::
          Vimage.t() | no_return()

  def center_crop!(%Vimage{} = image, crop_width, crop_height) do
    case center_crop(image, crop_width, crop_height) do
      {:ok, cropped} -> cropped
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Embeds an image in a larger image canvas, generating
  addition border pixels if required.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `width` is the width in pixels of the canvas
    image.

  * `height` is the height in pixels of the canvas
    image.

  * `options` is a keyword list of options.

  ### Options

  * `:x` is the x-offset into the canvas image
    where `image` will be embedded. The value may be
    a positive integer indicating a 0-based offset from
    the left of the canvas or a negative integer indicating
    a 1-based offset from the right side of the image.
    It may also be `:center` (the default) in which case the
    image will be centered horizontally within the canvas.

  * `:y` is the y-offset into the canvas image
    where `image` will be embedded. The value may be
    a positive integer indicating a 0-based offset from
    the top of the canvas or a negative integer indicating
    a 1-based offset from the bottom of the image.
    It may also be `:center` (the default) in which case the
    image will be centered vertically within the canvas.

  * `:background` defines the color of the generated background
    pixels. This can be specified as a single integer which will
    be applied to all bands, or a list of integers representing
    the color for each band. The color can also be supplied as a
    CSS color name as a string or atom. For example: `:misty_rose`.
    It can also be supplied as a hex string of
    the form `#rrggbb`. The default is `:black`. `:background` can
    also be set to `:average` in which case the background will be
    the average color of the base image. See also `Image.Color.color_map/0`
    and `Image.Color.rgb_color/1`.

  * `:background_transparency` defines the transparency of the
    `:background` pixels when `image` has an alpha band.
    The default is `:opaque`. The values are an integer in the
    range `0..255` where `0` is transparent and `255` is opaque.
    The number can also be a float in the range `0.0` to `1.0`.
    In this case the float is converted to an integer in the range
    `0..255`. Lastly, the atoms `:transparent` and `:opaque` can
    also be used.

  * `:extend_mode` determines how any additional pixels
    are generated. The values are:

    * `:black` (the default) meaning the generated pixels are
      black.
    * `:white` meaning the generated pixels are white.
    * `:copy` means the generated pixels take the value of the
      nearest edge pixel of the base image.
    * `:repeat` means the generated pixels are tiles from the
      base image.
    * `:mirror` means the generated pixels are reflected tiles of
      the base image.
    * `:background` means the generated pixels are the `:background`
      color set in `options`.

  ### Returns

  * `{:ok, embedded_image}` or

  * `{:error, reason}`

  """
  @doc subject: "Resize", since: "0.27.0"

  @spec embed(image :: Vimage.t(), width :: non_neg_integer(), height :: non_neg_integer(), options :: Options.Embed.embed_options()) ::
          {:ok, Vimage.t()} | {:error, error_message}

  def embed(image, width, height, options \\ []) do
    with {:ok, options} <- Options.Embed.validate_options(image, width, height, options) do
      embed_options = [background: options.background, extend: options.extend_mode]
      Operation.embed(image, options.x, options.y, width, height, embed_options)
    end
  end

  @doc """
  Embeds an image in a larger image canvas, generating
  addition border pixels if required.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `width` is the width in pixels of the canvas
    image.

  * `height` is the height in pixels of the canvas
    image.

  * `options` is a keyword list of options.

  ### Options

  See `Image.embed/4`.

  ### Returns

  * `embedded_image` or

  * raises an exception.

  """
  @doc subject: "Operation", since: "0.27.0"

  @spec embed!(Vimage.t(), non_neg_integer(), non_neg_integer(), Options.Embed.embed_options()) ::
          Vimage.t() | no_return

  def embed!(image, width, height, options \\ []) do
    case embed(image, width, height, options) do
      {:ok, embedded} -> embedded
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Replace one color in an image with another.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `options` is a keyword list of options.

  ### Options

  With the exception of the option `:replace_with`, the
  options for specifying the color or color range
  to be replaced are passed to `Image.chroma_mask/2`.

  * `:blend` is a boolean indicating if a the replacement
    should blend at the border of the color replacement.
    The default is `false`.

  * `:replace_with` is the replacement color.  This can be specified as
    a single integer which wil be applied to all bands, or a
    list of integers representing the color for each band. The
    color can also be supplied as a CSS color name as a string or
    atom. For example: `:misty_rose`. It can also be supplied as a
    hex string of the form `#rrggbb`. The default is `:black`.
    See also `Image.Color.color_map/0` and `Image.Color.validate_color/1`.

  There are two strategies available for selecting the
  color or color range to be replaced: the
  thresholding strategy (default) and the color
  range strategy.

  #### Threshold strategy

  * `:color` is an RGB color which represents the the
    chroma key to be selected. The color can be an
    integer between `0..255`, a three-element list of
    integers representing an RGB color or an atom
    representing a CSS color name. The default is
    `:auto` in which the average of the top left `10x10`
    pixels of the image is used.

  * `:threshold`is a positive integer to indicate the
    threshold around `:color` when calculating the mask.
    The default is `20`.

  #### Color range strategy

  * `:greater_than` is an RGB color which represents the upper
     end of the color range to be selected. The color can be an
     integer between `0..255`, a three-element list of
     integers representing an RGB color or an atom
     representing a CSS color name.

  * `:less_than` is an RGB color which represents the lower
     end of the color range to be selected. The color can be an
     integer between `0..255`, a three-element list of
     integers representing an RGB color or an atom
     representing a CSS color name.

  ### Returns

  * `{:ok, image}` or

  * `{:error, reason}`.

  """
  @doc since: "0.30.0", subject: "Color"

  @spec replace_color(Vimage.t(), ChromaKey.chroma_key_options() | [{:replace_with, Color.t()}]) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def replace_color(%Vimage{} = image, options \\ []) do
    {to_color, options} = Keyword.pop(options, :replace_with, :black)
    {blend, options} = Keyword.pop(options, :blend, false)
    xres = Vix.Vips.Image.xres(image)
    yres = Vix.Vips.Image.yres(image)

    with {:ok, to_color} <- Color.validate_color(to_color),
         {:ok, chroma_mask} <- chroma_mask(image, options),
         {:ok, inverted} <- Operation.invert(chroma_mask),
         {:ok, blend} = if_then_else(inverted, to_color, image, blend: blend) do
      Operation.copy(blend, xres: xres, yres: yres)
    end
  end

  @doc """
  Replace one color in an image with another or
  raises an exception.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `options` is a keyword list of options.

  ### Options

  With the exception of the option `:replace_with`, the
  options for specifying the color or color range
  to be replaced are passed to `Image.chroma_mask/2`.

  * `:replace_with` is the replacement color.  This can be specified as
    a single integer which wil be applied to all bands, or a
    list of integers representing the color for each band. The
    color can also be supplied as a CSS color name as a string or
    atom. For example: `:misty_rose`. It can also be supplied as a
    hex string of the form `#rrggbb`. The default is `:black`.
    See also `Image.Color.color_map/0` and `Image.Color.validate_color/1`.

  There are two strategies available for selecting the
  color or color range to be replaced: the
  thresholding strategy (default) and the color
  range strategy.

  #### Threshold strategy

  * `:color` is an RGB color which represents the the
    chroma key to be selected. The color can be an
    integer between `0..255`, a three-element list of
    integers representing an RGB color or an atom
    representing a CSS color name. The default is
    `:auto` in which the average of the top left `10x10`
    pixels of the image is used.

  * `:threshold`is a positive integer to indicate the
    threshold around `:color` when calculating the mask.
    The default is `20`.

  #### Color range strategy

  * `:greater_than` is an RGB color which represents the upper
     end of the color range to be selected. The color can be an
     integer between `0..255`, a three-element list of
     integers representing an RGB color or an atom
     representing a CSS color name.

  * `:less_than` is an RGB color which represents the lower
     end of the color range to be selected. The color can be an
     integer between `0..255`, a three-element list of
     integers representing an RGB color or an atom
     representing a CSS color name.

  ### Returns

  * `image` or

  * raises an exception.

  """
  @doc since: "0.30.0", subject: "Color"

  @spec replace_color!(Vimage.t(), ChromaKey.chroma_key_options() | [{:replace_with, Color.t()}]) ::
          Vimage.t() | no_return()

  def replace_color!(%Vimage{} = image, options \\ []) do
    case replace_color(image, options) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Trims an image to the bounding box of the non-background
  area.

  The image is median-filtered, all the row and column sums
  of the absolute difference from background are calculated
  in a single pass.

  Then the first row or column in each of the four directions
  where the sum is greater than threshold gives the bounding
  box that is used to define the crop area.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `options` is a keyword list of options.

  ### Options

  * `:background` is the color to be considered
    the background color. The default is automatically
    detected by averaging the pixels at the top
    left of the image. If background is set to
    `:alpha` then the image is trimmed to the size
    of the alpha mask.

  * `:threshold` is the integer threshold (or color
    similarity) that is applied when determining the
    bounds of the non-background area. The default is
    `10`. The default value means only a small color
    background color range is considered.  Increasing
    the threshold value maybe required.

  ### Returns

  * `{:ok, cropped_image}` which is the image
    cropped to the bounding box of the non-background
    area.

  * `{:error, reason}`.  Reason may be
    `:uncropped` which means the image was
    considered to be only the background color.

  """
  @doc subject: "Resize", since: "0.23.0"

  @spec trim(image :: Vimage.t(), options :: Options.Trim.trim_options()) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def trim(%Vimage{} = image, options \\ []) do
    case Keyword.pop(options, :background) do
      {:alpha, other_options} ->
        trim_to_alpha(image, other_options)

      _other ->
        trim_to_color(image, options)
    end
  end

  defp trim_to_color(image, options) do
    with {:ok, options} <- Options.Trim.validate_options(options) do
      background = maybe_calculate_color(image, options.background)
      threshold = options.threshold

      case Operation.find_trim(image, background: background, threshold: threshold) do
        {:ok, {_left, _top, 0, 0}} ->
          {:error, nothing_to_trim_error()}

        {:ok, {left, top, width, height}} ->
          Image.crop(image, left, top, width, height)

        error ->
          error
      end
    end
  end

  defp trim_to_alpha(%Vimage{} = image, options) do
    image
    |> split_alpha()
    |> trim_to_alpha(image, options)
  end

  defp trim_to_alpha({_other_bands, alpha}, image, options) when not is_nil(alpha) do
    options = Keyword.put(options, :background, [0, 0, 0])

    with {:ok, options} <- Options.Trim.validate_options(options) do
      case Operation.find_trim(alpha,
             background: options.background,
             threshold: options.threshold
           ) do
        {:ok, {_left, _top, 0, 0}} ->
          {:error, nothing_to_trim_error()}

        {:ok, {left, top, width, height}} ->
          Image.crop(image, left, top, width, height)

        error ->
          error
      end
    end
  end

  defp trim_to_alpha({_other_bands, nil}, _image, _options) do
    {:error, {Image.Error, "Image has no alpha band"}}
  end

  defp nothing_to_trim_error do
    {Image.Error, "Could not find anything to trim"}
  end

  @doc """
  Trims an image to the bounding box of the non-background
  area or raises an exception.

  The image is median-filtered, all the row and column sums
  of the absolute difference from background are calculated
  in a single pass.

  Then the first row or column in each of the four directions
  where the sum is greater than threshold gives the bounding
  box that is used to define the crop area.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `options` is a keyword list of options.

  ### Options

  * `:background` is the color to be considered
    the background color. The default is automatically
    detected by averaging the pixels at the top
    left of the image. If background is set to
    `:alpha` then the image is trimmed to the size
    of the alpha mask.

  * `:threshold` is the integer threshold (or color
    similarity) that is applied when determining the
    bounds of the non-background area. The default is
    `10`. The default value means only a small color
    background color range is considered.  Increasing
    the threshold value maybe required.

  ### Returns

  * `cropped_image` which is the image
    cropped to the bounding box of the non-background
    area or

  * raises an exception.

  """
  @doc subject: "Resize", since: "0.23.0"

  @spec trim!(image :: Vimage.t(), options :: Options.Trim.trim_options()) ::
          Vimage.t() | no_return()

  def trim!(%Vimage{} = image, options \\ []) do
    case trim(image, options) do
      {:ok, trimmed} -> trimmed
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Flatten an alpha layer out of an image.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * `{:ok, flattened_image}` or

  * `{:error, reason}`

  """
  @doc subject: "Operation", since: "0.23.0"

  @spec flatten(image :: Vimage.t()) :: {:ok, Vimage.t()} | {:error, error_message()}
  def flatten(%Vimage{} = image) do
    if has_alpha?(image) do
      Vix.Vips.Operation.flatten(image)
    else
      {:ok, image}
    end
  end

  @doc """
  Flatten an alpha layer out of an image
  or raises an exception.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * `flattened_image` or

  * raises an exception

  """
  @doc subject: "Operation", since: "0.23.0"

  @spec flatten!(image :: Vimage.t()) :: Vimage.t() | no_return()
  def flatten!(%Vimage{} = image) do
    case flatten(image) do
      {:ok, flattened} -> flattened
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Dilate an image mask, adding a pixels to the
  edge of the mask.

  Mask is used in the sense of an image
  on a transparent background. The results on
  other image types is undefined.

  The added pixels are the same color as the edge
  pixels in the mask.

  ### Note

  Dilate works for any non-complex image type, with any
  number of bands. The input is expanded by copying
  edge pixels before performing the operation so that
  the output image has the same size as the input.

  Edge pixels in the output image are therefore only
  approximate.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `pixels` is a positive integer number of
    pixels to dilate. The default is `1`.

  ### Returns

  * `{:ok, dilated_mask}` or

  * `{:error, reason}`

  """
  @doc subject: "Operation", since: "0.23.0"

  @spec dilate(image :: Vimage.t(), pixels :: pos_integer) ::
          {:ok, Vimage.t()} | {:error, error_message}
  def dilate(image, pixels \\ 1) when is_integer(pixels) and pixels > 0 do
    Enum.reduce_while(1..pixels, {:ok, image}, fn
      _pixel, {:ok, image} ->
        {:cont, Vix.Vips.Operation.rank(image, 3, 3, 8)}

      _pixel, {:error, reason} ->
        {:halt, {:error, reason}}
    end)
  end

  @doc """
  Dilate an image mask, adding a pixels to the
  edge of the mask or raising an exception.

  Mask is used in the sense of an image
  on a transparent background. The results on
  other image types is undefined.

  The added pixels are the same color as the edge
  pixels in the mask.

  ### Note

  Dilate works for any non-complex image type, with any
  number of bands. The input is expanded by copying
  edge pixels before performing the operation so that
  the output image has the same size as the input.

  Edge pixels in the output image are therefore only
  approximate.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `pixels` is a positive integer number of
    pixels to dilate. The default is `1`.

  ### Returns

  * `dilated_mask` or

  * raises an exception

  """
  @doc subject: "Operation", since: "0.23.0"

  @spec dilate!(image :: Vimage.t(), pixels :: pos_integer) :: Vimage.t() | no_return()
  def dilate!(%Vimage{} = image, pixels \\ 1) when is_integer(pixels) and pixels > 0 do
    case dilate(image, pixels) do
      {:ok, dilated} -> dilated
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Erode an image mask, removing pixels from the
  edge of the mask.

  Mask is used in the sense of an image
  on a transparent background. The results on
  other image types is undefined.

  ### Note

  Erode works for any non-complex image type, with any
  number of bands. The input is expanded by copying
  edge pixels before performing the operation so that
  the output image has the same size as the input.

  Edge pixels in the output image are therefore only
  approximate.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `pixels` is a positive integer number of
    pixels to dilate. The default is `1`.

  ### Returns

  * `{:ok, eroded_mask}` or

  * `{:error, reason}`

  """
  @doc subject: "Operation", since: "0.23.0"

  @spec erode(image :: Vimage.t(), pixels :: pos_integer) ::
          {:ok, Vimage.t()} | {:error, error_message}
  def erode(image, pixels \\ 1) when is_integer(pixels) and pixels > 0 do
    Enum.reduce_while(1..pixels, {:ok, image}, fn
      _pixel, {:ok, image} ->
        {:cont, Vix.Vips.Operation.rank(image, 3, 3, 0)}

      _pixel, {:error, reason} ->
        {:halt, {:error, reason}}
    end)
  end

  @doc """
  Erode an image mask, removing pixels from the
  edge of the mask or raising an exception.

  Mask is used in the sense of an image
  on a transparent background. The results on
  other image types is undefined.

  ### Note

  Erode works for any non-complex image type, with any
  number of bands. The input is expanded by copying
  edge pixels before performing the operation so that
  the output image has the same size as the input.

  Edge pixels in the output image are therefore only
  approximate.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `pixels` is a positive integer number of
    pixels to dilate. The default is `1`.

  ### Returns

  * `eroded_mask` or

  * raises an exception

  """
  @doc subject: "Operation", since: "0.23.0"

  @spec erode!(image :: Vimage.t(), pixels :: pos_integer) :: Vimage.t() | no_return()
  def erode!(%Vimage{} = image, pixels \\ 1) when is_integer(pixels) and pixels > 0 do
    case erode(image, pixels) do
      {:ok, eroded} -> eroded
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Rotate an image clockwise (to the
  right) by a number of degrees.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `angle` is a `float` number of degrees
    to rotate in a clockwise direction.

  * `options` is a keyword list of options.

  ### Options

  * `:idy` is the vertical input displacement which
    defaults to `0.0`

  * `:idx` is the horizontal input displacement which
    defaults to `0.0`

  * `:ody` is the vertical output displacement
    which defaults to `0.0`

  * `:odx` is the horizontal output displacement
    which defaults to `0.0`

  * `:background` is the background color to be used for filling
    the blank areas of the image. The background is specified as
    a list of 3 or 4 float values depending on the image
    color space.

  ## Notes

  The displacement parameters cause the image canvas to be
  expanded and the image displaced, relative to the top left
  corner of the image, by the amount specified.

  The rules defining how the image canvas is expanded
  is not known to the author of `Image`. Experimentation will
  be required if you explore these options.

  ### Returns

  * `{:ok, rotated_image}` or

  * `{:error, reason}`

  """
  @doc subject: "Operation"

  @spec rotate(
          image :: Vimage.t(),
          angle :: float(),
          options :: Options.Rotate.rotation_options()
        ) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def rotate(%Vimage{} = image, angle, options \\ []) when is_number(angle) do
    with {:ok, options} <- Options.Rotate.validate_options(options) do
      Operation.rotate(image, angle, options)
    end
  end

  @doc """
  Rotate an image clockwise (to the
  right) by a number of degrees.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `angle` is a `float` number of degrees
    to rotate in a clockwise direction.

  * `options` is a keyword list of options.
    See `Image.rotate/3`.

  ## Notes

  The displacement parameters cause the image canvas to be
  expanded and the image displaced, relative to the top left
  corner of the image, by the amount specified.

  The rules defining how the image canvas is expanded
  is not known to the author of `Image`. Experimentation will
  be required if you explore these options.

  ### Returns

  * `rotated_image` or

  * raises an exception.

  """
  @doc subject: "Operation"

  @spec rotate!(
          image :: Vimage.t(),
          angle :: float(),
          options :: Options.Rotate.rotation_options()
        ) ::
          Vimage.t() | no_return()

  def rotate!(%Vimage{} = image, angle, options \\ []) when is_number(angle) do
    case rotate(image, angle, options) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Rotate an image based upon the orientation
  information in an image's EXIF data.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * `{:ok, {auto_rotated_image, flags}}` or

  * `{:error, reason}`

  ### Flags

  Two flags are returned indicating what action
  was taken:

  * `:flip` which is a boolean indicating if the image
    was flipped or not and

  * `:angle` through which the image was rotated.
    This value will be one of `0`, `90`, `180` or
    `270` representing the degrees of rotation.

  """
  @doc subject: "Operation"

  @spec autorotate(image :: Vimage.t()) ::
          {:ok, {Vimage.t(), map()}} | {:error, error_message()}

  def autorotate(%Vimage{} = image) do
    case Operation.autorot(image) do
      {:ok, {image, flags}} ->
        {:ok, {image, decode_rotation_flags(flags)}}

      other ->
        other
    end
  end

  @rotation_encoding %{
    VIPS_ANGLE_D0: 0,
    VIPS_ANGLE_D90: 90,
    VIPS_ANGLE_D180: 180,
    VIPS_ANGLE_D270: 270
  }

  defp decode_rotation_flags(flags) do
    angle = Map.fetch!(flags, :angle)
    angle = Map.fetch!(@rotation_encoding, angle)

    Map.put(flags, :angle, angle)
  end

  @doc """
  Rotate an image based upon the orientation
  information in an image's EXIF data. Returns
  a potentially rotated image or raises and
  exception.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * `auto_rotated_image` or

  * raises an exception.

  """
  @doc subject: "Operation"

  @spec autorotate!(image :: Vimage.t()) ::
          Vimage.t() | no_return()

  def autorotate!(image) do
    case autorotate(image) do
      {:ok, {image, _flags}} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Adds a concentric ripple effect to an image.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * `{:ok, image_with_ripple}` or

  * `{:error, reason}`

  """
  @dialyzer {:nowarn_function, {:ripple, 1}}
  @doc subject: "Operation"

  @spec ripple(Vimage.t()) :: {:ok, Vimage.t()} | {:error, error_message()}
  def ripple(%Vimage{} = image) do
    use Image.Math

    width = width(image)
    height = height(image)

    # this makes an image where pixel (0, 0) (at the top-left) has value [0, 0],
    # and pixel (image.width, image.height) at the bottom-right has value
    # [image.width, image.height]
    {:ok, index} = Operation.xyz(width, height)

    # make a version with (0, 0) at the centre, negative values up and left,
    # positive down and right
    center = index - [width / 2, height / 2]

    # to polar space, so each pixel is now distance and angle in degrees
    {:ok, polar} = Complex.polar(center)

    # scale sin(distance) by 1/distance to make a wavey pattern
    d = 10_000 * sin!(polar[0] * 3) / (1 + polar[0])

    # and back to rectangular coordinates again to make a set of vectors we can
    # apply to the original index image
    {:ok, joined} = Operation.bandjoin([d, polar[1]])
    {:ok, rectangular} = Complex.rectangular(joined)
    index = index + rectangular

    # finally, use our modified index image to distort the input!
    Operation.mapim(image, index)
  end

  @doc """
  Adds a concentric ripple effect to an image
  returning an image or raising an exception.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * `image_with_ripple` or

  * raises an exception.

  """
  @dialyzer {:nowarn_function, {:ripple!, 1}}
  @doc subject: "Operation"

  @spec ripple!(Vimage.t()) :: Vimage.t() | no_return()
  def ripple!(%Vimage{} = image) do
    case ripple(image) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Apply a circular mask to an image.

  The returned image has an alpha
  band masking the circular image.

  As a result, it is best saved to a
  format, like `.png` that supports
  alpha transparency.

  Note that `.jpg` files do not support
  alpha transparency.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * `{:ok, circular_image}` or

  * `{:error, reason}`

  """
  @doc subject: "Mask"

  @spec circle(Vimage.t(), Keyword.t()) :: {:ok, Vimage.t()} | {:error, error_message()}
  def circle(%Vimage{} = image, _options \\ []) do
    width = width(image)
    height = height(image)
    size = min(width, height)

    {:ok, mask} = mask(:circle, size, size)
    Operation.bandjoin([image, mask])
  end

  @doc """
  Apply a circular mask to an image
  returning an image or raising an
  exception.

  The returned image has an alpha
  band masking the circular image.

  As a result, it is best saved to a
  format, like `.png` that supports
  alpha transparency.

  Note that `.jpg` files do not support
  alpha transparency.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * `circular_image` or

  * raises an exception.

  """
  @doc subject: "Mask"

  @spec circle!(Vimage.t(), Keyword.t()) :: Vimage.t() | no_return()
  def circle!(%Vimage{} = image, options \\ []) do
    case circle(image, options) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Apply rounded corners to an image.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `options` is a keyword list of options.

  ### Options

  * `:radius` is the desired corner radius.
    The default is #{@default_round_corner_radius}.

  ### Returns

  * `{:ok, rounded_corner_image}` or

  * `{:error, reason}`

  """
  @doc subject: "Generator"

  @spec rounded(Vimage.t(), Keyword.t()) :: {:ok, Vimage.t()} | {:error, error_message()}
  def rounded(%Vimage{} = image, options \\ []) do
    options = Keyword.put_new(options, :radius, @default_round_corner_radius)
    width = width(image)
    height = height(image)

    {:ok, mask} = mask(:rounded_corners, width, height, options)
    Operation.bandjoin([image, mask])
  end

  @doc """
  Apply rounded corners to an image. Returns
  an image or raises an exception.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `options` is a keyword list of options.

  ### Options

  * `:radius` is the desired corner radius.
    The default is #{@default_round_corner_radius}.

  ### Returns

  * `rounded_corner_image` or

  * raises an exception.

  """
  @doc subject: "Mask"

  @spec rounded!(Vimage.t(), Keyword.t()) :: Vimage.t() | no_return()
  def rounded!(%Vimage{} = image, options \\ []) do
    case rounded(image, options) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Apply squircle mask to an image.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `options` is a keyword list of options.

  ### Options

  * `:radius` is the desired squircle radius.
    The default is #{@default_squircle_radius}.

  ### Returns

  * `{:ok, squircle_image}` or

  * `{:error, reason}`

  """
  @doc subject: "Generator"

  @spec squircle(Vimage.t(), Keyword.t()) :: {:ok, Vimage.t()} | {:error, error_message()}
  def squircle(%Vimage{} = image, options \\ []) do
    options = Keyword.put_new(options, :radius, @default_squircle_radius)
    width = width(image)
    height = height(image)

    {:ok, mask} = mask(:squircle, width, height, options)
    Operation.bandjoin([image, mask])
  end

  @doc """
  Apply a squircle mask to an image. Returns
  an image or raises an exception.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `options` is a keyword list of options.

  ### Options

  * `:radius` is the desired squircle radius.
    The default is #{@default_squircle_radius}.

  ### Returns

  * `squircle_image` or

  * raises an exception.

  """
  @doc subject: "Mask"

  @spec squircle!(Vimage.t(), Keyword.t()) :: Vimage.t() | no_return()
  def squircle!(%Vimage{} = image, options \\ []) do
    case squircle(image, options) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  # Create an image mask (alpha transparency) that can
  # then be applied to an image.

  # At some point this will become a public API.

  defp mask(type, width, height, options \\ [])

  defp mask(:circle, diameter, diameter, _options) do
    centre = div(diameter, 2)

    svg = """
    <svg viewBox="0 0 #{diameter} #{diameter}">
      <circle style="fill: black; stroke: none" cx="#{centre}" cy="#{centre}" r="#{centre}"/>
    </svg>
    """

    {:ok, {circle, _flags}} = Operation.svgload_buffer(svg)
    Operation.extract_band(circle, alpha_band(circle))
  end

  defp mask(:rounded_corners, width, height, options) do
    radius = Keyword.get(options, :radius, @default_round_corner_radius)

    svg = """
    <svg viewBox="0 0 #{width} #{height}">
      <rect rx="#{radius}" ry="#{radius}" x="0" y="0" width="#{width}" height="#{height}" fill="black" />
    </svg>
    """

    {:ok, {mask, _flags}} = Operation.svgload_buffer(svg)
    Operation.extract_band(mask, alpha_band(mask))
  end

  defp mask(:squircle, width, height, options) do
    r = Keyword.get(options, :radius, @default_squircle_radius)
    h2 = div(height, 2)
    w2 = div(width, 2)
    hr = height - r
    wr = width - r

    svg = """
    <svg viewBox="0 0 #{width} #{height}">
      <path d="M 0 #{h2} C 0 #{r}, #{r} 0, #{w2} 0 S #{width} #{r}, #{width} #{h2}, #{wr} #{height} #{w2} #{height}, 0 #{hr}, 0 #{h2}" fill="black" />
    </svg>
    """

    {:ok, {mask, _flags}} = Operation.svgload_buffer(svg)
    Operation.extract_band(mask, alpha_band(mask))
  end

  @doc """
  Minimize metadata by keeping only the artist
  and copyright (if available).

  Removing metadata from an image can greatly reduce
  the overall size of an image. The proportional
  reduction is most noticeable with smaller images
  which are very common in web applications.

  Removing all metadata is a common option however
  with intellectual property concerns in mind
  this function will keep the artist and
  copyright fields if they exist in the original
  image.

  On a 1000x500px image exported from Adobe Lightroom
  with metadata intact, removing the metadata
  results in am approximately 50% saving in file
  size due to the removal of most EXIF and all
  IPTC and XMP metadata.

  Note that the minimized metadata is only materialized when
  the minimized image is saved to a file.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`

  ### Returns

  * `{:ok, image_with_minimal_metadata}` or

  * `{:error, reason}`

  """
  @doc subject: "Metadata"

  @spec minimize_metadata(image :: Vimage.t()) :: {:ok, Vimage.t()} | {:error, error_message()}
  def minimize_metadata(%Vimage{} = image) do
    with {:ok, exif} <- exif(image),
         {:ok, image} <- remove_metadata(image) do
      Vimage.mutate(image, fn mut_img ->
        :ok = Exif.put_metadata(mut_img, :copyright, exif.copyright)
        :ok = Exif.put_metadata(mut_img, :artist, exif.artist)
      end)
    end
  end

  @doc """
  Minimize metadata by keeping only the artist
  and copyright (if available).

  See also `Image.minimize_metadata/1`.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`

  ### Returns

  * ` image_with_minimal_metadata` or

  * raises an exception.

  """
  @doc subject: "Metadata"

  @spec minimize_metadata!(image :: Vimage.t()) :: Vimage.t() | no_return()
  def minimize_metadata!(%Vimage{} = image) do
    case minimize_metadata(image) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @metadata_fields %{
    exif: "exif-data",
    xmp: "xmp-dataa",
    iptc: "iptc-data"
  }

  @metadata_names Map.keys(@metadata_fields)

  @doc """
  Remove metadata from an image returning
  an updated image or raising an exception.

  This can significantly reduce the size of
  an image file.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`

  * `fields` is a list of metadata field names
    as strings. The default is all known
    field names. There are some special field
    names interpreted by `Image` to simplify
    metadata removal these are:

    * `:exif` which means remove all
      [EXIF](https://en.wikipedia.org/wiki/Exif) metadata
    * `:iptc` which means remove all
      [IPTC](https://en.wikipedia.org/wiki/IPTC_Information_Interchange_Model) metadata
    * `:xmp` which means remove all
      [xmp](https://en.wikipedia.org/wiki/Extensible_Metadata_Platform) data

  ## Notes

  * The available field names (ie. metadata fields)
    in an image can be returned with a call to
    `Vix.Vips.Image.header_field_names/1`.

  * Errors removing metadata fields is not propagated
    into the return for this function. Errors might occur
    when attempting to remove metadata fields that
    do not exist in the image.

  ### Returns

    * `{:ok, image_without_metadata_fields}` or

    * `{:error, reason}`

  """
  @doc subject: "Metadata"

  @spec remove_metadata(Vimage.t(), list(binary() | atom())) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def remove_metadata(image, fields \\ [])

  def remove_metadata(image, field) when not is_list(field) do
    remove_metadata(image, List.wrap(field))
  end

  def remove_metadata(image, []) do
    {:ok, fields} = Vimage.header_field_names(image)
    remove_metadata(image, fields)
  end

  def remove_metadata(%Vimage{} = image, fields) when is_list(fields) do
    Vimage.mutate(image, fn mut_img ->
      Enum.each(fields, &remove_meta(mut_img, &1))
    end)
  end

  @doc """
  Remove metadata from an image returning
  an image or raising an exception.

  This can significant;y reduce the size of
  an image file.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`

  * `fields` is a list of metadata field names
    as strings. The default is all known
    field names. There are some special field
    names interpreted by `Image` to simplify
    metadata removal these are:

    * `:exif` which means remove all
      [EXIF](https://en.wikipedia.org/wiki/Exif) metadata
    * `:iptc` which means remove all
      [IPTC](https://en.wikipedia.org/wiki/IPTC_Information_Interchange_Model) metadata
    * `:xmp` which means remove all
      [xmp](https://en.wikipedia.org/wiki/Extensible_Metadata_Platform) data

  ## Notes

  * The available field names (ie. metadata fields)
    in an image can be returned with a call to
    `Vix.Vips.Image.header_field_names/1`.

  * Errors removing metadata fields is not propagated
    into the return for this function. Errors might occur
    when attempting to remove metadata fields that
    do not exist in the image.

  ### Returns

    * `image_without_metadata_fields` or

    * raises an exception.

  """
  @doc subject: "Metadata"

  @spec remove_metadata!(Vimage.t(), list(binary() | atom())) :: Vimage.t() | no_return()
  def remove_metadata!(image, fields \\ []) do
    case remove_metadata(image, fields) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  defp remove_meta(image, field) when is_atom(field) and field in @metadata_names do
    field = Map.fetch!(@metadata_fields, field)
    remove_meta(image, field)
  end

  defp remove_meta(image, field) do
    MutableImage.remove(image, field)
  end

  @y_band 1

  @doc """
  Create an image gradient of the same size as
  the given image.

  The gradient will interpolate from the `start`
  value to the `finish` value. The default `start`
  value is black with 100% transparency. The
  default `finish` value is black with 100% opacity.

  `start` and `finish` are given as an `rgb` triplet
  or quadruplet list of integers between `0` and `255`.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`

  * `:start is an `rgb` triplet or quadruplet
    list of numbers between `0` and `255`.

  * `:finish is an `rgb` triplet or quadruplet
    list of numbers between `0` and `255`.

  ### Returns

  * `{:ok, gradient_image}` or

  * `{:error, reason}`

  ### Example

      # transparent_black and opaque_black are the default
      # start and finish values
      transparent_black = [0, 0, 0, 0]
      opaque_black = [0, 0, 0, 255]
      {:ok, gradient} = Image.linear_gradient(image, transparent_black, opaque_black)

  """
  @dialyzer {:nowarn_function, {:linear_gradient, 1}}
  @dialyzer {:nowarn_function, {:linear_gradient, 2}}
  @dialyzer {:nowarn_function, {:linear_gradient, 3}}

  @start_color [0, 0, 0, 0]
  @finish_color [0, 0, 0, 255]

  @doc subject: "Generator"

  @spec linear_gradient(Vimage.t(), start :: Color.rgb_color(), finish :: Color.rgb_color()) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def linear_gradient(%Vimage{} = image, start \\ @start_color, finish \\ @finish_color) do
    use Image.Math

    width = width(image)
    height = height(image)

    {:ok, xyz} = Operation.xyz(width, height)
    {:ok, y} = Operation.extract_band(xyz, @y_band)

    # the distance image: 0 - 1 for the start to the end of the gradient
    d = y / height

    # and use it to fade the quads ... we need to tag the result as an RGB
    # image
    (d * finish + (1 - d) * start)
    |> Operation.copy(interpretation: :VIPS_INTERPRETATION_sRGB)
  end

  @doc """
  Create an image gradient of the same size as
  the given image. Returns the gradient image
  or raises and exception.

  The gradient will interpolate from the `start`
  value to the `finish` value. The default `start`
  value is black with 100% transparency. The
  default `finish` value is black with 100% opacity.

  `start` and `finish` are given as an `rgb` triplet
  or quadruplet list of integers between `0` and `255`.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`

  * `:start is an `rgb` triplet or quadruplet
    list of numbers between `0` and `255`.

  * `:finish is an `rgb` triplet or quadruplet
    list of numbers between `0` and `255`.

  ### Returns

  * `gradient_image` or

  * raises an exception.

  ### Example

      # transparent_black and opaque_black are the default
      # start and finish values
      transparent_black = [0, 0, 0, 0]
      opaque_black = [0, 0, 0, 255]
      gradient = Image.linear_gradient!(image, transparent_black, opaque_black)

  """
  @dialyzer {:nowarn_function, {:linear_gradient!, 1}}
  @dialyzer {:nowarn_function, {:linear_gradient!, 2}}
  @dialyzer {:nowarn_function, {:linear_gradient!, 3}}

  @doc subject: "Generator"

  @spec linear_gradient!(Vimage.t(), start :: Color.rgb_color(), finish :: Color.rgb_color()) ::
          Vimage.t() | no_return()

  def linear_gradient!(%Vimage{} = image, start \\ @start_color, finish \\ @finish_color) do
    case linear_gradient(image, start, finish) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Returns a radial gradient as an image.

  This image might then be composited over
  another image.

  ### Arguments

  * `width` is the width of the gradient in
    pixels.

  * `height` is the height of the gradient in
    pixels.

  * `options` is a keyword list of options. The
    default is `[]`.

  ### Options

  * `:start` is the color from which the gradient
    starts in the center of the image.

  * `:finish` is the color at which the gradient
    finishes at the end of the gradient.

  * `:feather` is the slope of the gradient. That it,
    how quickly the gradient moves from the `:start`
    color to the `:finish` color. The valid range is
    `1..10` representing the smallest amount of feather
    (harshest transition) to the largest amount of
    feather (smoothest transition).

  ### Returns

  * `{:ok, gradient_image}` or

  * `{:error, reason}`

  """
  @dialyzer {:nowarn_function, {:radial_gradient, 2}}
  @dialyzer {:nowarn_function, {:radial_gradient, 3}}

  @doc subject: "Generator", since: "0.6.0"

  @spec radial_gradient(width :: pos_integer(), height :: pos_integer(), options :: Keyword.t()) ::
          {:ok, %Vimage{}} | {:error, error_message()}

  def radial_gradient(width, height, options \\ []) do
    use Image.Math

    # Lab colors, not RGB
    # Since rgba 0 for transparency means
    # transparent, and 1 means opaque we
    # transition from black to white
    start = [0, 0, 0]
    finish = [100, 0, 0]

    max = max(width, height)

    # Take a number 1..10
    feather = Keyword.get(options, :feather, 1)

    # Range of 0.5 to 3 -> probably linear
    radius = Keyword.get(options, :radius, 2)

    x = Operation.xyz!(width, height) - [width / 2, height / 2]

    d = (x[0] ** 2 + x[1] ** 2) ** 0.5 / (2 ** (feather * 0.05) * max / radius)
    out = d * finish + (d * -1 + 1) * start

    Operation.copy(out, interpretation: :VIPS_INTERPRETATION_LAB)
  end

  @doc """
  Returns the dominant color of an image
  as an RBG triplet value in an integer
  list.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `options` is a keyword list of options.
    The default is `[]`.

  ### Options

  * `:bins` is an integer number of color
   frequency bins the image is divided into.
   The default is `10`.

  ### Returns

  * `[r, g, b]`

  """
  @max_band_value 256

  @doc subject: "Image info", since: "0.3.0"

  @spec dominant_color(Vimage.t(), Keyword.t()) :: Color.rgb_color()
  def dominant_color(%Vimage{} = image, options \\ []) do
    bins = Keyword.get(options, :bins, 10)
    bin_size = @max_band_value / bins
    midpoint = bin_size / 2

    {:ok, histogram} = Operation.hist_find_ndim(image, bins: bins)
    {v, x, y} = Image.Math.maxpos(histogram)
    {:ok, pixel} = Operation.getpoint(histogram, x, y)
    z = Enum.find_index(pixel, &(&1 == v))

    r = x * bin_size + midpoint
    g = y * bin_size + midpoint
    b = z * bin_size + midpoint

    [round(r), round(g), round(b)]
  end

  @doc """
  Returns the histogram for an image.

  The histogram is returned as a `t:Vimage.t/0`
  that is a 255 by 255 image the same numbers of
  bands as the source image.

  ### Argument

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * `{:ok, histogram_image}` or

  * `{:error, reason}`

  ### Notes

  The returned image is is organized
  as a 256x256 pixel image with
  the same number of bands as the original
  image.

  Each pixel on the image returns the count
  of pixels in the original image that are
  in that 1/256th part of the image.

  """
  @doc subject: "Operation", since: "0.3.0"

  @spec histogram(Vimage.t()) :: {:ok, Vimage.t()} | {:error, error_message()}
  def histogram(%Vimage{} = image) do
    image
    |> Operation.hist_find!()
    |> Operation.hist_norm()
  end

  @doc """
  Returns the pixel value at the given image location.

  The returned pixel is a list of numbers where
  the length of the list is equal to the number
  of bands in the image.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `x` is an integer offset from the top
    left of the image along the `x` (width) axis.
    The number must be in the range `0..width - 1`.

  * `y` is an integer offset from the top
    left of the image along the `y` (height) axis.
    The number must be in the range `0..height - 1`.

  ### Returns

  * `{:ok, pixel_value}` or

  * `{:error, reason}`

  """
  @doc subject: "Operation", since: "0.3.0"

  @spec get_pixel(Vimage.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, Color.rgb_color()} | {:error, error_message()}

  def get_pixel(%Vimage{} = image, x, y) do
    with {:ok, values} <- Operation.getpoint(image, x, y) do
      {:ok, Enum.map(values, &round/1)}
    end
  end

  @doc """
  Returns the pixel value at the given image location
  or raises an exception.

  The returned pixel is a list of numbers where
  the length of the list is equal to the number
  of bands in the image.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `x` is an integer offset from the top
    left of the image along the `x` (width) axis.
    The number must be in the range `0..width - 1`.

  * `y` is an integer offset from the top
    left of the image along the `y` (height) axis.
    The number must be in the range `0..height - 1`.

  ### Returns

  * `pixel_value` or

  * raises an exception

  """
  @doc subject: "Operation", since: "0.26.0"

  @spec get_pixel!(Vimage.t(), non_neg_integer(), non_neg_integer()) ::
          Color.rgb_color() | no_return()

  def get_pixel!(%Vimage{} = image, x, y) do
    case get_pixel(image, x, y) do
      {:ok, pixel} -> pixel
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Mutate an image with through the given
  function.

  Mutations, like those functions in the
  `Image.Draw`, module are operations on
  a *copy* of the base image and operations
  are serialized through a genserver in order
  to maintain thread safety.

  In order to perform multiple mutations without
  coopying for each each mutation,`Image.mutate/2` takes
  a function argument `fun` that is passed a
  `t:Vix.Vips.MutableImage.t/0` as a parameter. In that
  way several mutations can be safely applied withouout
  copying the image prior to each mutation.

  Although the image is not copied before each mutuation,
  each mutable operation is still serialized behind
  a genserver to ensure thread safety.

  The functions in `Image.Draw` all support either
  a `t:Vix.Vips.Image.t/0` or a `t:Vix.Vips.MutableImage.t/0`
  as the image parameter.

  When the parameter `fun` returns, the mutation
  process is ended and a normal `t:Vix.Vips.Image.t/0`
  is returned.

  This function is a convenience wrapper
  around `Vix.Vips.Image.mutate/2`.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `fun` is any 1-arity function that receives
    a `t:Vix.Vips.MutableImage.t/0` parameter.

  ### Returns

  * `{:ok, mutated_image}` or

  * `{:error, reason}`

  ### Example

        # The image is copied and operations
        # are serialized behind a genserver.
        # Only one copy is made but all operations
        # will be serialized behind a genserver.
        # When the function returns the genserver
        # is broken down and the underlying
        # mutated `t:Vix.Vips.Image.t/0` is returned.

        Image.mutate image, fn mutable_image ->
          mutable_image
          |> Image.Draw.rect!(0, 0, 10, 10, color: :red)
          |> Image.Draw.rect!(10, 10, 20, 20, color: :green)
        end

  """
  @doc subject: "Operation", since: "0.7.0"

  @spec mutate(Vimage.t(), (Vix.Vips.MutableImage.t() -> any())) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def mutate(%Vimage{} = image, fun) when is_function(fun, 1) do
    Vimage.mutate(image, fun)
  end

  @doc """
  Converts an image to the given colorspace.

  Available colorspaces are returned from
  `Image.Interpretation.known_interpretations/0`.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`

  * `colorspace` is any known colorspace. See
    `Image.Interpretation.known_interpretations/0`
    for a list of the known colorspaces.

  ### Returns

  * `{;ok, image_in_new_colorspace}` or

  * `{:error, reason}`

  ### Example

      Image.to_colorspace(image, :bw)

  """
  @doc subject: "Color"

  @spec to_colorspace(Vimage.t(), Interpretation.t()) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def to_colorspace(%Vimage{} = image, colorspace) do
    with {:ok, colorspace} <- Interpretation.validate_interpretation(colorspace) do
      Vix.Vips.Operation.colourspace(image, colorspace)
    end
  end

  @doc """
  Converts an impage to the given colorspace returning
  an image or raising an exception.

  Available colorspaces are returned from
  `Image.Interpretation.known_interpretations/0`.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`

  * `colorspace` is any known colorspace. See
    `Image.Interpretation.known_interpretations/0`
    for a list of the known colorspaces.

  ### Returns

  * `image_in_new_colorspace` or

  * raises an exception

  ### Example

      Image.to_colorspace!(image, :bw)

  """
  @doc subject: "Color"

  @spec to_colorspace!(Vimage.t(), Interpretation.t()) ::
          Vimage.t() | no_return()

  def to_colorspace!(%Vimage{} = image, colorspace) do
    case to_colorspace(image, colorspace) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Convert image to polar coordinates.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * `{:ok, image_in_polar_coordinates}` or

  * `{:error, reason}`

  """
  @dialyzer {:nowarn_function, {:to_polar_coordinates, 1}}
  @doc subject: "Operation"

  @spec to_polar_coordinates(Vimage.t()) :: {:ok, Vimage.t()} | {:error, error_message()}
  def to_polar_coordinates(%Vimage{} = image) do
    use Image.Math

    width = width(image)
    height = height(image)

    xy = Operation.xyz!(width, height)
    xy = xy - [width / 2.0, height / 2.0]

    scale = min(width, height) / width
    xy = xy * 2.0 / scale

    {:ok, index} = Complex.polar(xy)
    index = index * [1.0, height / 360.0]

    Operation.mapim(image, index)
  end

  @doc """
  Convert image to polar coordinates returning
  an image or raising an exception.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * `image_in_polar_coordinates` or

  * raises an exception.

  """
  @dialyzer {:nowarn_function, {:to_polar_coordinates!, 1}}
  @doc subject: "Operation"

  @spec to_polar_coordinates!(Vimage.t()) :: Vimage.t() | no_return()
  def to_polar_coordinates!(%Vimage{} = image) do
    case to_polar_coordinates(image) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Convert image to rectangular coordinates.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ## Notes

  Roundtrip to polar and back to rectangular
  coordinates displays some image distortion,
  likely due to rounding errors in float
  arithmetic. Further study is required.

  ### Returns

  * `{:ok, image_in_rectangular_coordinates}` or

  * `{:error, reason}`

  """
  @dialyzer {:nowarn_function, {:to_rectangular_coordinates, 1}}
  @doc subject: "Operation"

  @spec to_rectangular_coordinates(Vimage.t()) :: {:ok, Vimage.t()} | {:error, error_message()}
  def to_rectangular_coordinates(%Vimage{} = image) do
    use Image.Math

    width = width(image)
    height = height(image)

    xy = Operation.xyz!(width, height)
    xy = xy * [1.0, 360.0 / height]

    {:ok, index} = Complex.rectangular(xy)
    scale = min(width, height) / width

    index = index * scale / 2.0
    index = index + [width / 2.0, height / 2.0]

    Operation.mapim(image, index)
  end

  @doc """
  Convert image to rectangular coordinates
  returning an image or raising an exception.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ## Notes

  Roundtrip to polar and back to rectangular
  coordinates displays some image distortion,
  likely due to rounding errors in float
  arithmetic. Further study is required.

  ### Returns

  * `image_in_rectangular_coordinates` or

  * raises an exception.

  """
  @dialyzer {:nowarn_function, {:to_rectangular_coordinates!, 1}}
  @doc subject: "Operation"

  @spec to_rectangular_coordinates!(Vimage.t()) :: Vimage.t() | no_return()
  def to_rectangular_coordinates!(%Vimage{} = image) do
    case to_rectangular_coordinates(image) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Apply a percentage adjustment to an image's brightness
  (luminance).

  The image is converted to the `lch` color space, multiplies the
  luminance band by the provided float percentage and converts
  the image back to its original color space.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `brightness` is any float greater than `0.0`. A number less
    than `1.0` means reduce brightness. A number greater than `1.0`
    means increas brightness.

  ### Returns

  * `{:ok, adjusted_image}` or

  * `{:error, reason}`.

  """
  @doc since: "0.34.0"
  @doc subject: "Operation"

  @spec brightness(image :: Vimage.t(), brightness :: float()) ::
          {:ok, Vimage.t()} | {:error, error_message()}
  def brightness(%Vimage{} = image, brightness) when is_multiplier(brightness) do
    with_colorspace(image, :lch, fn i ->
      Image.Math.multiply(i, [brightness, 1.0, 1.0])
    end)
  end

  @doc """
  Apply a percentage adjustment to an image's brightness
  (luminance) or raises an exception.

  The image is converted to the `lch` color space, multiplies the
  luminance band by the provided float percentage and converts
  the image back to its original color space.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `brightness` is any float greater than `0.0`. A number less
    than `1.0` means reduce brightness. A number greater than `1.0`
    means increas brightness.

  ### Returns

  * `adjusted_image` or

  * raises an exception.

  """
  @doc since: "0.34.0"
  @doc subject: "Operation"

  @spec brightness!(image :: Vimage.t(), brightness :: float()) :: Vimage.t() | no_return()
  def brightness!(%Vimage{} = image, brightness) when is_multiplier(brightness) do
    case brightness(image, brightness) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Apply a percentage adjustment to an image's contrast.

  This is a simple implementation that applies a linear
  function to the image. In most cases, `Image.apply_tone_curve/2`
  should be preferred for making constrast adjustments.

  Small increments can have a dramatic affect on the image;
  contrast in the range of approximately `0.5` to `1.5` are
  likely to meet most requirement.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `contrast` is any float greater than `0.0`. A number less
    than `1.0` means reduce contrast. A number greater than `1.0`
    means increase contrast.

  ### Returns

  * `{:ok, adjusted_image}` or

  * `{:error, reason}`.

  """

  # Implementation is based upon https://stackoverflow.com/questions/73601395/adjusting-contrast-in-vips-the-same-way-as-the-matching-css-filter

  @doc since: "0.35.0"
  @doc subject: "Operation"

  @spec contrast(image :: Vimage.t(), contrast :: float()) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def contrast(%Vimage{} = image, contrast) when is_multiplier(contrast) do
    use Image.Math

    source_colorspace = interpretation(image)

    with {:ok, scrgb} <- to_colorspace(image, :scrgb) do
      contrasted = scrgb * contrast - (0.5 * contrast - 0.5)
      to_colorspace(contrasted, source_colorspace)
    end
  end

  def contrast(%Vimage{} = _image, contrast) do
    {:error,
     "Invalid contrast value. Contrast must be a float greater that 0.0. Found #{inspect(contrast)}"}
  end

  @doc """
  Apply a percentage adjustment to an image's contrast or
  raises and exception.

  This is a simple implementation that applies a linear
  function to the image. In most cases, `Image.apply_tone_curve/2`
  should be preferred for making constrast adjustments.

  Small increments can have a dramatic affect on the image;
  contrast in the range of approximately `0.5` to `1.5` are
  likely to meet most requirement.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `contrast` is any float greater than `0.0`. A number less
    than `1.0` means reduce contrast. A number greater than `1.0`
    means increase contrast.

  ### Returns

  * `adjusted_image` or

  * raises an exception.

  """
  @doc since: "0.35.0"
  @doc subject: "Operation"

  @spec contrast!(image :: Vimage.t(), contrast :: float()) :: Vimage.t() | no_return()
  def contrast!(%Vimage{} = image, contrast) when is_multiplier(contrast) do
    case contrast(image, contrast) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Transforms an image using brightness, saturation,
  hue rotation, and lightness.

  Brightness and lightness both operate on luminance,
  with the difference being that brightness is multiplicative
  whereas lightness is additive.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `options` is a keyword list of options.

  ### Options

  * `:brightness` is any float greater than `0.0`. A number less
    than `1.0` means reduce brightness. A number greater than `1.0`
    means increas brightness.  The default is `1.0` meaning no
    brightness adjustment.

  * `:lightness` is any float. This value is added to the luminance
    of an image. This is different to `:brightness` which is *multuplied*
    by the luminance. The default is `0.0` meaning no lightness
    adjustment.

  * `:saturation` is any float greater than `0.0`. A number less
    than `1.0` means reduce saturation. A number greater than `1.0`
    means increas saturation. The default is `1.0` meaning no
    saturation adjustment.

  * `:hue` is an integer angle in degrees added to the hue. This is often
    referred to as the *hug angle* and the operation as adjusting
    the *hue rotation*. The value should typically be in the range `0..360`.
    The default is `0` meaning no hue adjustment.

  ### Returns

  * `{:ok, modulated_image}` or

  * `{:error, reason}`.

  """
  @doc since: "0.35.0"
  @doc subject: "Operation"

  @spec modulate(image :: Vimage.t(), options :: Options.Modulate.modulate_options()) ::
          {:ok, Vimage.t()} | {:error, error_message}

  def modulate(%Vimage{} = image, options \\ []) do
    with {:ok, options} <- Options.Modulate.validate_options(options) do
      without_alpha_band(image, fn image ->
        with_colorspace(image, :lch, fn image ->
          multipliers = [options.brightness, options.saturation, 1.0]
          addends = [options.lightness, 0.0, options.hue]
          Operation.linear(image, multipliers, addends)
        end)
      end)
    end
  end

  @doc """
  Transforms an image using brightness, saturation,
  hue rotation, and lightness or raises an exception.

  Brightness and lightness both operate on luminance,
  with the difference being that brightness is multiplicative
  whereas lightness is additive.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `options` is a keyword list of options.

  ### Options

  * `:brightness` is any float greater than `0.0`. A number less
    than `1.0` means reduce brightness. A number greater than `1.0`
    means increas brightness.  The default is `1.0` meaning no
    brightness adjustment.

  * `:lightness` is any float. This value is added to the luminance
    of an image. This is different to `:brightness` which is *multuplied*
    by the luminance. The default is `0.0` meaning no lightness
    adjustment.

  * `:saturation` is any float greater than `0.0`. A number less
    than `1.0` means reduce saturation. A number greater than `1.0`
    means increas saturation. The default is `1.0` meaning no
    saturation adjustment.

  * `:hue` is an integer angle in degrees added to the hue. This is often
    referred to as the *hug angle* and the operation as adjusting
    the *hue rotation*. The value should typically be in the range `0..360`.
    The default is `0` meaning no hue adjustment.

  ### Returns

  * `modulated_image` or

  * raises an exception.

  """
  @doc since: "0.35.0"
  @doc subject: "Operation"

  @spec modulate!(image :: Vimage.t(), options :: Options.Modulate.modulate_options()) ::
          Vimage.t() | no_return()

  def modulate!(%Vimage{} = image, options \\ []) do
    case modulate(image, options) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Equalizes the histogram of an imaage.

  Equalization is the process of expanding the
  tone range of an image by stretching the darkest
  tones towards black and the lightest tones towards
  white. As a result, equalization affects overall
  image contrast.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `bands` determines which bands are equalized. The
    value may be one of:

    * `:all` (defaalt) means that all bands are eqalized
      such that the darkest tones are expanded to black and the
      lightest tones are expanded to white.

    * `:each` means that each band is equalized individually
      such that each band is expanded to fill the range
      between 5% and 95% of the available tone range. Since
      each band is equalized separately there may be some
      color shifts detected.

    * `:luminance` means that only the luminance band is
      equqlized to fill between 1% and 99% of the tone range.
      The image is converted to the `:lab` color space, the
      `l` band is equalized and the image is converted back to
      its origianal color space.

  ### Returns

  * `{:ok, adjusted_image}` or

  * `{:error, reason}`.

  """
  @doc since: "0.35.0"
  @doc subject: "Operation"

  @spec equalize(image :: Vimage.t(), bands :: Options.Equalize.equalize_option()) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def equalize(image, bands \\ :all)

  def equalize(%Vimage{} = image, :all) do
    without_alpha_band(image, fn image ->
      Operation.hist_equal(image)
    end)
  end

  def equalize(%Vimage{} = image, :each) do
    use Image.Math

    band_format = Vix.Vips.Image.format(image)

    without_alpha_band(image, fn image ->
      with_colorspace(image, :srgb, fn image ->
        bands =
          image
          |> Operation.hist_find!()
          |> split_bands()

        low = Enum.map(bands, &level_percent(&1, @level_trim_percent))
        high = Enum.map(bands, &level_percent(&1, 100 - @level_trim_percent))
        scale = for {h, l} <- Enum.zip(high, low), do: 255.0 / (h - l)
        scaled = (image - low) * scale

        Operation.cast(scaled, band_format)
      end)
    end)
  end

  def equalize(%Vimage{} = image, :luminance) do
    without_alpha_band(image, fn image ->
      with_colorspace(image, :lab, fn lab_image ->
        luminance = lab_image[0]
        min = Operation.percent!(luminance, @min_luminance)
        max = Operation.percent!(luminance, @max_luminance)

        normalize_if_possible(lab_image, luminance, min, max)
      end)
    end)
  end

  def equalize(%Vimage{} = _image, bands) do
    {:error,
     "Invalid bands parameter. Valid parameters are :all, :each and :luminance. Found #{inspect(bands)}."}
  end

  defp level_percent(hist, percentage) do
    use Image.Math

    norm =
      hist
      |> Operation.hist_cum!()
      |> Operation.hist_norm!()

    {:ok, {_c, r}} = Operation.profile(norm > width(norm) * percentage / 100)

    Operation.avg!(r)
  end

  defp normalize_if_possible(lab_image, luminance, min, max) when abs(max - min) >= 1 do
    f = 100.0 / (max - min)
    a = -(min * f)

    luminance
    |> Operation.linear!([f], [a])
    |> bandjoin(lab_image[1..2])
  end

  defp normalize_if_possible(lab_image, _luminance, _min, _max) do
    {:ok, lab_image}
  end

  @doc """
  Apply a global contrast adjustment to an image
  or raises an exception.

  Equalization is the process of expanding the
  tone range of an image by stretching the darkest
  tones towards black and the lightest tones towards
  white. As a result, equalization affects overall
  image contrast.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `bands` determines which bands are equalized. The
    value may be one of:

    * `:all` (defaalt) means that all bands are eqalized
      such that the darkest tones are expanded to black and the
      lightest tones are expanded to white.

    * `:each` means that each band is equalized individually
      such that each band is expanded to fill the range
      between 5% and 95% of the available tone range. Since
      each band is equalized separately there may be some
      color shifts detected.

    * `:luminance` means that only the luminance band is
      equqlized to fill between 1% and 99% of the tone range.
      The image is converted to the `:lab` color space, the
      `l` band is equalized and the image is converted back to
      its origianal color space.

  ### Returns

  * `adjusted_image` or

  * raises an exception.

  """
  @doc since: "0.35.0"
  @doc subject: "Operation"

  @spec equalize!(image :: Vimage.t(), bands :: Options.Equalize.equalize_option()) ::
          Vimage.t() | no_return()

  def equalize!(%Vimage{} = image, bands \\ :all) do
    case equalize(image, bands) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Applies a tone curve to an image.

  A [tone curve](https://en.wikipedia.org/wiki/Curve_(tonality))
  is typically used to affect overall image contrast. It
  is a function to adjust brightness and contrast by controlling the
  input-output density curve for each band of an image.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `options` is a keyword list of options.

  ### Options

  * `:black_point` is an integer between `0`
    (the default) and `100` indicating the darkest
    and most dense black area of the image will
    lie in the overall range of the image.

  * `:white_point` is an integer between `0`
    and `100` (the default) indicating the lightest
    area of the image will lie in the overall range
    of the image.

  * `:shadow_point` is the point on the tone curve
    around which the shadow values are tone mapped. The
    value is between `0.0` and `1.0`. The default is
    `0.2`.

  * `:mid_point` is the point on the tone curve
    around which the mid tone values are tone mapped. The
    value is between `0.0` and `1.0`. The default is
    `0.5`.

  * `:highlight_point` is the point on the tone curve
    around which the highlight values are tone mapped. The
    value is between `0.0` and `1.0`. The default is
    `0.8`.

  * `:shadows` indicates by how much the shadows should be
    adjusted. The value is in the range `-30` to `30`.
    The default is `0`.

  * `:mid_points` indicates by how much the mid tones should be
    adjusted. The value is in the range `-30` to `30`.
    The default is `0`.

  * `:highlights` indicates by how much the highlights should be
    adjusted. The value is in the range `-30` to `30`.
    The default is `0`.

  ### Returns

  * `{:ok, tone_mapped_image}` or

  * `{:error, reason}`.

  """
  @doc since: "0.35.0"
  @doc subject: "Operation"

  @spec apply_tone_curve(image :: Vimage.t(), options :: Options.ToneCurve.tone_curve_options()) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def apply_tone_curve(%Vimage{} = image, options \\ []) do
    with {:ok, lut} <- tone_curve(image, options) do
      without_alpha_band(image, fn base_image ->
        Operation.maplut(base_image, lut)
      end)
    end
  end

  @doc """
  Applies a tone curve to an image or raises
  an exception.

  A [tone curve](https://en.wikipedia.org/wiki/Curve_(tonality))
  is typically used to affect overall image contrast. It
  is a function to adjust brightness and contrast by controlling the
  input-output density curve for each band of an image.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `options` is a keyword list of options.

  ### Options

  * `:black_point` is an integer between `0`
    (the default) and `100` indicating the darkest
    and most dense black area of the image will
    lie in the overall range of the image.

  * `:white_point` is an integer between `0`
    and `100` (the default) indicating the lightest
    area of the image will lie in the overall range
    of the image.

  * `:shadow_point` is the point on the tone curve
    around which the shadow values are tone mapped. The
    value is between `0.0` and `1.0`. The default is
    `0.2`.

  * `:mid_point` is the point on the tone curve
    around which the mid tone values are tone mapped. The
    value is between `0.0` and `1.0`. The default is
    `0.5`.

  * `:highlight_point` is the point on the tone curve
    around which the highlight values are tone mapped. The
    value is between `0.0` and `1.0`. The default is
    `0.8`.

  * `:shadows` indicates by how much the shadows should be
    adjusted. The value is in the range `-30` to `30`.
    The default is `0`.

  * `:mid_points` indicates by how much the mid tones should be
    adjusted. The value is in the range `-30` to `30`.
    The default is `0`.

  * `:highlights` indicates by how much the highlights should be
    adjusted. The value is in the range `-30` to `30`.
    The default is `0`.

  ### Returns

  * `tone_mapped_image` or

  * raises an exception.

  """
  @doc since: "0.35.0"
  @doc subject: "Operation"

  @spec apply_tone_curve!(image :: Vimage.t(), options :: Options.ToneCurve.tone_curve_options()) ::
          Vimage.t() | no_return()

  def apply_tone_curve!(%Vimage{} = image, options \\ []) do
    case apply_tone_curve(image, options) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  defp tone_curve(%Vimage{} = image, options) do
    {_min, _max} = range(image)

    with {:ok, options} <- Options.ToneCurve.validate_options(options),
         {_min, max} <- range(image),
         {:ok, lut} <-
           Operation.tonelut(
             Lb: options.black_point,
             Lw: options.white_point,
             Ps: options.shadow_point,
             Pm: options.mid_point,
             Ph: options.highlight_point,
             S: options.shadows,
             M: options.mid_points,
             H: options.highlights,
             "in-max": max,
             "out-max": max
           ) do
      cast(lut, band_format(image))
    end
  end

  @doc """
  Apply a local contrast adjustment to an image.

  This function applies a [Constrast Limited Adaptive histogram equalization (AHE)](https://en.wikipedia.org/wiki/Adaptive_histogram_equalization#Contrast_Limited_AHE)
  to improve contrast in images. It differs from ordinary histogram
  equalization in the respect that the adaptive method computes several
  histograms, each corresponding to a distinct section of the image, and
  uses them to redistribute the lightness values of the image.

  It is therefore suitable for improving the local contrast and
  enhancing the definitions of edges in each region of an image,
  hence the name of the function.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `options` is a keyword list of options.

  ### Options

  * :`window_size` is an integer indicating the size of
    the window (in pixels) into the image in which the contrast adjustment
    is calculated. The default is `3`.

  * `:max_slope` is the integral level of brightening, between 0 and
    100, where 0 (the default) disables contrast limiting.

  ### Returns

  * `{:ok, adjusted_image}` or

  * `{:error, reason}`.

  """
  @doc since: "0.35.0"
  @doc subject: "Operation"

  @spec local_contrast(
          image :: Vimage.t(),
          options :: Options.LocalContrast.local_contrast_options()
        ) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def local_contrast(%Vimage{} = image, options \\ []) do
    with {:ok, options} <- Options.LocalContrast.validate_options(options) do
      window = options.window_size
      Operation.hist_local(image, window, window, "max-slope": options.max_slope)
    end
  end

  @doc """
  Apply a local contrast adjustment to an image
  or raises an exception.

  This function applies a [Constrast Limited Adaptive histogram equalization (AHE)](https://en.wikipedia.org/wiki/Adaptive_histogram_equalization#Contrast_Limited_AHE)
  to improve contrast in images. It differs from ordinary histogram
  equalization in the respect that the adaptive method computes several
  histograms, each corresponding to a distinct section of the image, and
  uses them to redistribute the lightness values of the image.

  It is therefore suitable for improving the local contrast and
  enhancing the definitions of edges in each region of an image,
  hence the name of the function.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `options` is a keyword list of options.

  ### Options

  * :`window_size` is an integer indicating the size of
    the window (in pixels) into the image in which the contrast adjustment
    is calculated. The default is `3`.

  * `:max_slope` is the integral level of brightening, between 0 and
    100, where 0 (the default) disables contrast limiting.

  ### Returns

  * `adjusted_image` or

  * raises an exception.

  """
  @doc since: "0.35.0"
  @doc subject: "Operation"

  @spec local_contrast!(
          image :: Vimage.t(),
          options :: Options.LocalContrast.local_contrast_options()
        ) ::
          Vimage.t() | no_return()

  def local_contrast!(%Vimage{} = image, options \\ []) do
    case local_contrast(image, options) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Apply an adjustment to an image's saturation
  (chroma).

  The image is converted to the `lch` color space, multiplies the
  chroma band by the provided float and converts
  the image back to its original color space.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `saturation` is any float greater than `0.0`. A number less
    than `1.0` means reduce saturation. A number greater than `1.0`
    means increas saturation.

  ### Returns

  * `{:ok, adjusted_image}` or

  * `{:error, reason}`.

  """
  @doc since: "0.34.0"
  @doc subject: "Operation"

  @spec saturation(image :: Vimage.t(), saturation :: float()) ::
          {:ok, Vimage.t()} | {:error, error_message()}
  def saturation(%Vimage{} = image, saturation) when is_multiplier(saturation) do
    with_colorspace(image, :lch, fn i ->
      Image.Math.multiply(i, [1.0, saturation, 1.0])
    end)
  end

  @doc """
  Apply an adjustment to an image's saturation
  (chroma) or raises an exception.

  The image is converted to the `lch` color space, multiplies the
  chroma band by the provided float and converts
  the image back to its original color space.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `saturation` is any float greater than `0.0`. A number less
    than `1.0` means reduce saturation. A number greater than `1.0`
    means increas saturation.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `saturation` is any float greater than `0.0`. A number less
    than `1.0` means reduce saturation. A number greater than `1.0`
    means increas saturation.

  ### Returns

  * `adjusted_image` or

  * raises an exception.

  """
  @doc since: "0.34.0"
  @doc subject: "Operation"

  @spec saturation!(image :: Vimage.t(), saturation :: float()) :: Vimage.t() | no_return()
  def saturation!(%Vimage{} = image, saturation) when is_multiplier(saturation) do
    case saturation(image, saturation) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Reduces noise in an image by applying a median
  filter.

  The implementation uses a [median rank filter](https://en.wikipedia.org/wiki/Median_filter)
  based on ordering the pixel values under a convolution kernel of a given
  window size and extracting the median value.

  The result is appropriate for removing
  [salt and pepper noise](https://en.wikipedia.org/wiki/Salt-and-pepper_noise) and
  may be useful for smoothing gaussian noise in some cases.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `window_size` is the integer size of the convolution kernel use
    in the median rank filter. The default is `3`.

  ### Returns

  * `{:ok, reduced_noise_image}` or

  * `{:error, reason}`

  """
  @doc since: "0.35.0"
  @doc subject: "Operation"

  @spec reduce_noise(image :: Vimage.t(), window_size :: pos_integer()) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def reduce_noise(%Vimage{} = image, window_size \\ @default_median_window_size) do
    Operation.rank(image, window_size, window_size, div(window_size * window_size, 2))
  end

  @doc """
  Reduces noise in an image by applying a median
  filter or raises an exception.

  The implementation uses a [median rank filter](https://en.wikipedia.org/wiki/Median_filter)
  based on ordering the pixel values under a convolution kernel of a given
  window size and extracting the median value.

  The result is appropriate for removing
  [salt and pepper noise](https://en.wikipedia.org/wiki/Salt-and-pepper_noise) and
  may be useful for smoothing gaussian noise in some cases.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `window_size` is the integer size of the convolution kernel use
    in the median rank filter. The default is `3`.

  ### Returns

  * `reduced_noise_image` or

  * raises an exception.

  """
  @doc since: "0.35.0"
  @doc subject: "Operation"

  @spec reduce_noise!(image :: Vimage.t(), window_size :: pos_integer()) ::
          Vimage.t() | no_return()

  def reduce_noise!(%Vimage{} = image, window_size \\ @default_median_window_size) do
    case reduce_noise(image, window_size) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  if match?({:module, _module}, Code.ensure_compiled(Nx)) do
    @doc """
    Converts an image into an [Nx](https://hex.pm/packages/nx)
    tensor.

    ### Arguments

    * `image` is any `t:Vimage.t/0`

    * `options` is a keyword list of options

    ### Options

    * `:shape` determines how the tensor is shaped. The valid
      values are:

      * `:whb` or `:whc` which leaves the tensor unchanged with
        the underlying data in `width, height, bands` shape.
        This is the default action.

      * `:hwc` or `:hwb` which reshapes the tensor to
        `height, width, channels` which is commonly used
        for machine learning models.

    ### Returns

    * `{:ok, tensor)` where tensor is an `t:Nx.Tensor.t/0` tensor
      suitable for use in the `Nx` library or

    * `{:error, reason}`.

    ### Example

        iex> {:ok, image} = Vix.Vips.Operation.black(3, 3)
        iex> Image.to_nx(image, backend: Nx.BinaryBackend)
        {:ok,
          Nx.tensor([[[0], [0], [0]], [[0], [0], [0]], [[0], [0], [0]]],
            type: {:u, 8}, names: [:width, :height, :bands], backend: Nx.BinaryBackend)}

    """

    # For some reason dialyzer thinks Vix.Vips.Image.write_to_tensor/1
    # can only return `{:error, _}`.
    @dialyzer {:nowarn_function, {:to_nx, 1}}
    @dialyzer {:nowarn_function, {:to_nx, 2}}

    @default_shape :whb

    @doc subject: "Matrix", since: "0.5.0"

    @spec to_nx(image :: Vimage.t(), options :: Keyword.t()) ::
            {:ok, Nx.Tensor.t()} | {:error, error_message()}

    def to_nx(%Vimage{} = image, options \\ []) do
      {to_shape, options} = Keyword.pop(options, :shape, @default_shape)

      with {:ok, tensor} <- Vix.Vips.Image.write_to_tensor(image),
           {:ok, shape, names} <- maybe_reshape_tensor(tensor, to_shape) do
        %Vix.Tensor{data: binary, type: type} = tensor

        binary
        |> Nx.from_binary(type, options)
        |> Nx.reshape(shape, names: names)
        |> wrap(:ok)
      end
    end

    # Because of the dialyzer issue for to_nx/2, dialyzer then
    # thinks this function won't be called.
    @dialyzer {:nowarn_function, {:maybe_reshape_tensor, 2}}

    defp maybe_reshape_tensor(%Vix.Tensor{shape: shape, names: names}, :whb),
      do: {:ok, shape, names}

    defp maybe_reshape_tensor(%Vix.Tensor{shape: shape, names: names}, :whc),
      do: {:ok, shape, names}

    defp maybe_reshape_tensor(%Vix.Tensor{} = tensor, :hwb),
      do: maybe_reshape_tensor(tensor, :hwc)

    defp maybe_reshape_tensor(%Vix.Tensor{shape: {width, height, bands}}, :hwc),
      do: {:ok, {height, width, bands}, [:height, :width, :channels]}

    defp maybe_reshape_tensor(_tensor, shape) do
      {:error,
       "Invalid shape. Allowable shapes are :whb, :whc, :hwc and :hwb. Found #{inspect(shape)}"}
    end

    @doc """
    Converts an image into an [Nx](https://hex.pm/packages/nx)
    tensor.

    ### Arguments

    * `image` is any `t:Vimage.t/0`

    * `options` is a keyword list of options

    ### Options

    * `:shape` determines how the tensor is shaped. The valid
      values are:

      * `:whb` or `:whc` which leaves the tensor unchanged with
        the underlying data in `width, height, bands` shape.
        This is the default action.

      * `:hwc` or `:hwb` which reshapes the tensor to
        `height, width, channels` which is commonly used
        for machine learning models.

    ### Returns

    * `tensor` where tensor is an `t:Nx.Tensor.t/0` tensor
      suitable for use in the `Nx` library or

    * raises an exception.

    ### Example

        iex> {:ok, image} = Vix.Vips.Operation.black(3, 3)
        iex> Image.to_nx!(image, backend: Nx.BinaryBackend)
        Nx.tensor([[[0], [0], [0]], [[0], [0], [0]], [[0], [0], [0]]],
          type: {:u, 8}, names: [:width, :height, :bands], backend: Nx.BinaryBackend)

    """
    @doc subject: "Matrix", since: "0.27.0"

    # Because of the dialyzer issue for to_nx/2, dialyzer then
    # thinks this function has no local return.
    @dialyzer {:nowarn_function, {:to_nx!, 1}}
    @dialyzer {:nowarn_function, {:to_nx!, 2}}

    @spec to_nx!(image :: Vimage.t(), options :: Keyword.t()) ::
            Nx.Tensor.t() | no_return()

    def to_nx!(%Vimage{} = image, options \\ []) do
      case to_nx(image, options) do
        {:ok, tensor} -> tensor
        {:error, reason} -> raise Image.Error, reason
      end
    end

    @doc """
    Converts an [Nx](https://hex.pm/packages/nx) tensor
    into an image.

    ### Arguments

    * `tensor` is any three dimensional `t:Nx.Tensor.t/0`.

    * `options` is a keyword list of options. For valid
      options see `Nx.from_binary/2`.

    ### Returns

    * `{:ok, image}` or

    * `{:error, reason}`

    ### Notes

    In order to convert a tensor into an image it must
    satisfy these constraints:

    * It must have three dimensions.

    * It must have a tensor type that is compatible
      with `libvips` (most tensors will satisfy this
      requirement other than tensors whose type is complex).

    * The names of the axes must be `[:width, :height, any_other]`
      or `[:height, :width, any_other]`.

    ### Example

        iex> {:ok, image} = Vix.Vips.Operation.black(3, 3)
        iex> {:ok, tensor} = Image.to_nx(image)
        iex> {:ok, _image_2} = Image.from_nx(tensor)

    """
    @doc subject: "Matrix", since: "0.5.0"

    @spec from_nx(tensor :: Nx.Tensor.t()) :: {:ok, Vimage.t()} | {:error, error_message()}
    def from_nx(tensor) when is_struct(tensor, Nx.Tensor) do
      with {:ok, tensor_format} <- Image.BandFormat.image_format_from_nx(tensor) do
        case Nx.shape(tensor) do
          {x, y, bands} when bands in 1..5 ->
            {width, height} = dimensions_from_tensor(tensor, x, y)
            binary = Nx.to_binary(tensor)
            Vix.Vips.Image.new_from_binary(binary, width, height, bands, tensor_format)

          shape ->
            shape_error(shape)
        end
      end
    end

    defp dimensions_from_tensor(tensor, x, y) do
      case Nx.names(tensor) do
        [:height, _, _] -> {y, x}
        _other -> {x, y}
      end
    end

    defp shape_error(shape) do
      {:error,
       "The tensor must have the shape {height, width, bands} with bands between " <>
         "1 and 5. Found shape #{inspect(shape)}."}
    end

    @doc """
    Performs a warp perspective transformation on an
    image.

    Requires `Nx` to be configured as a dependency.

    ### Arguments

    * `image` is any `t:Vimage.t/0`

    * `source` is a list of four 2-tuples representing the
      four corners of the subject-of-interest in `image`.

    * `destination` is a list of four 2-tuples representing the
      four corners of the destination image into which the
      subject-of-interest is transformed.

    * `options` is a keyword list of options. The default
      is `[]`.

    ### Options

    * `:background` defines the color of any generated background
      pixels. This can be specified as a single integer which will
      be applied to all bands, or a list of integers representing
      the color for each band. The color can also be supplied as a
      CSS color name as a string or atom. For example: `:misty_rose`.
      It can also be supplied as a hex string of
      the form `#rrggbb`. The default is `:black`. `:background` can
      also be set to `:average` in which case the background will be
      the average color of the base image. See also `Image.Color.color_map/0`
      and `Image.Color.rgb_color/1`.

    * `:extend_mode` determines how any additional pixels
      are generated. The values are:

      * `:black` (the default) meaning the generated pixels are
        black.
      * `:white` meaning the generated pixels are white.
      * `:copy` means the generated pixels take the value of the
        nearest edge pixel of the base image.
      * `:repeat` means the generated pixels are tiles from the
        base image.
      * `:mirror` means the generated pixels are a reflected tiles of
        the base image.
      * `:background` means the generated pixels are the background
        color setin `options`.

    ### Notes

    * The image is flattened before warping and therefore any
      alpha band will be multiplied into to the image data and
      removed.

    ### Returns

    * `{:ok, warped_image}` or

    * `{:error, reason}`

    """
    @doc subject: "Operation", since: "0.28.0"

    @spec warp_perspective(
            Vimage.t(),
            source :: quadrilateral(),
            destination :: quadrilateral(),
            Options.WarpPerspective.t()
          ) ::
            {:ok, Vimage.t()} | {:error, error_message()}

    def warp_perspective(%Vimage{} = image, source, destination, options \\ []) do
      with {:ok, options} <- Options.WarpPerspective.validate_options(image, options),
           {:ok, flattened} <- flatten(image),
           {:ok, transform_map} <- transform_matrix(flattened, source, destination) do
        Operation.mapim(flattened, transform_map, options)
      end
    end

    @doc """
    Performs a warp perspective transformation on an
    image or raises an exception.

    Requires `Nx` to be configured as a dependency.

    ### Arguments

    * `image` is any `t:Vimage.t/0`

    * `source` is a list of four 2-tuples representing the
      four corners of the subject-of-interest in `image`.

    * `destination` is a list of four 2-tuples representing the
      four corners of the destination image into which the
      subject-of-interest is transformed.

    * `options` is a keyword list of options. The default
      is `[]`.

    ### Options

    * `:background` defines the color of any generated background
      pixels. This can be specified as a single integer which will
      be applied to all bands, or a list of integers representing
      the color for each band. The color can also be supplied as a
      CSS color name as a string or atom. For example: `:misty_rose`.
      It can also be supplied as a hex string of
      the form `#rrggbb`. The default is `:black`. `:background` can
      also be set to `:average` in which case the background will be
      the average color of the base image. See also `Image.Color.color_map/0`
      and `Image.Color.rgb_color/1`.

    * `:extend_mode` determines how any additional pixels
      are generated. The values are:

      * `:black` (the default) meaning the generated pixels are
        black.
      * `:white` meaning the generated pixels are white.
      * `:copy` means the generated pixels take the value of the
        nearest edge pixel of the base image.
      * `:repeat` means the generated pixels are tiles from the
        base image.
      * `:mirror` means the generated pixels are a reflected tiles of
        the base image.
      * `:background` means the generated pixels are the background
        color setin `options`.

    ### Returns

    * `warped_image` or

    * raises an exception.

    ### Notes

    * The image is flattened before warping and therefore any
      alpha band will be multiplied into to the image data and
      removed.

    """
    @doc subject: "Operation", since: "0.28.0"

    @spec warp_perspective!(
            Vimage.t(),
            source :: quadrilateral(),
            destination :: quadrilateral(),
            Options.WarpPerspective.t()
          ) ::
            Vimage.t() | no_return()

    def warp_perspective!(image, from, to, options \\ []) do
      case warp_perspective(image, from, to, options) do
        {:ok, image} -> image
        {:error, reason} -> raise Image.Error, reason
      end
    end

    @doc """
    Performs a warp perspective transformation on an
    image to straighten its perspective.

    Requires `Nx` to be configured as a dependency.

    ### Arguments

    * `image` is any `t:Vimage.t/0`

    * `source` is a list of four 2-tuples representing the
      four corners of the subject-of-interest in `image`.

    * `options` is a keyword list of options. The default
      is `[]`.

    ### Options

    * `:background` defines the color of any generated background
      pixels. This can be specified as a single integer which will
      be applied to all bands, or a list of integers representing
      the color for each band. The color can also be supplied as a
      CSS color name as a string or atom. For example: `:misty_rose`.
      It can also be supplied as a hex string of
      the form `#rrggbb`. The default is `:black`. `:background` can
      also be set to `:average` in which case the background will be
      the average color of the base image. See also `Image.Color.color_map/0`
      and `Image.Color.rgb_color/1`.

    * `:extend_mode` determines how any additional pixels
      are generated. The values are:

      * `:black` (the default) meaning the generated pixels are
        black.
      * `:white` meaning the generated pixels are white.
      * `:copy` means the generated pixels take the value of the
        nearest edge pixel of the base image.
      * `:repeat` means the generated pixels are tiles from the
        base image.
      * `:mirror` means the generated pixels are a reflected tiles of
        the base image.
      * `:background` means the generated pixels are the background
        color setin `options`.

    ### Returns

    * `{:ok, destination, straightened_image}` or

    * `{:error, reason}`

    ### Notes

    * The image is flattened before warping and therefore any
      alpha band will be multiplied into to the image data and
      removed.

    * The returned `destination` is a four element list of
      2-tuples representing the four points to which the `source`
      points were transformed. `destination` can be passed as
      a parameter to `Image.crop/2` to crop the transformed image
      to the subject-of-interest that was warped.

    """
    @doc subject: "Operation", since: "0.28.0"

    @spec straighten_perspective(
            Vimage.t(),
            source :: quadrilateral(),
            Options.WarpPerspective.t()
          ) ::
            {:ok, quadrilateral(), Vimage.t()} | {:error, error_message()}

    def straighten_perspective(%Vimage{} = image, source, options \\ []) do
      with [{sx1, sy1}, {sx2, _sy2}, {_sx3, _sy3}, {_sx4, sy4}] <- source do
        destination = [{sx1, sy1}, {sx2, sy1}, {sx2, sy4}, {sx1, sy4}]

        case warp_perspective(image, source, destination, options) do
          {:ok, warped} -> {:ok, destination, warped}
          other -> other
        end
      end
    end

    @doc """
    Performs a warp perspective transformation on an
    image to straighten its perspective or raises an
    exception.

    Requires `Nx` to be configured as a dependency.

    ### Arguments

    * `image` is any `t:Vimage.t/0`

    * `source` is a list of four 2-tuples representing the
      four corners of the subject-of-interest in `image`.

    * `options` is a keyword list of options. The default
      is `[]`.

    ### Options

    * `:background` defines the color of any generated background
      pixels. This can be specified as a single integer which will
      be applied to all bands, or a list of integers representing
      the color for each band. The color can also be supplied as a
      CSS color name as a string or atom. For example: `:misty_rose`.
      It can also be supplied as a hex string of
      the form `#rrggbb`. The default is `:black`. `:background` can
      also be set to `:average` in which case the background will be
      the average color of the base image. See also `Image.Color.color_map/0`
      and `Image.Color.rgb_color/1`.

    * `:extend_mode` determines how any additional pixels
      are generated. The values are:

      * `:black` (the default) meaning the generated pixels are
        black.
      * `:white` meaning the generated pixels are white.
      * `:copy` means the generated pixels take the value of the
        nearest edge pixel of the base image.
      * `:repeat` means the generated pixels are tiles from the
        base image.
      * `:mirror` means the generated pixels are a reflected tiles of
        the base image.
      * `:background` means the generated pixels are the background
        color setin `options`.

    ### Returns

    * `straightened_image` or

    * `{:error, reason}`

    ### Notes

    * The image is flattened before warping and therefore any
      alpha band will be multiplied into to the image data and
      removed.

    * The returned `destination` is a four element list of
      2-tuples representing the four points to which the `source`
      points were transformed. `destination` can be passed as
      a parameter to `Image.crop/2` to crop the transformed image
      to the subject-of-interest that was warped.

    """
    @doc subject: "Operation", since: "0.28.0"

    @spec straighten_perspective!(
            Vimage.t(),
            source :: quadrilateral(),
            Options.WarpPerspective.t()
          ) ::
            Vimage.t() | no_return()

    def straighten_perspective!(%Vimage{} = image, source, options \\ []) do
      with [{sx1, sy1}, {sx2, _sy2}, {_sx3, _sy3}, {_sx4, sy4}] <- source do
        destination = [{sx1, sy1}, {sx2, sy1}, {sx2, sy4}, {sx1, sy4}]

        case warp_perspective(image, source, destination, options) do
          {:ok, warped} -> warped
          {:error, reason} -> raise Image.Error, reason
        end
      end
    end

    @doc """
    Returns a transformation matrix for a given
    image, source quadrilateral and desintation quadrilateral.

    A transformation matrix when applied to an image
    (using, for example, `Image.map/2`) maps pixels from
    the source persecptive to the destination perspective.

    Requires `Nx` to be configured as a dependency.

    ### Arguments

    * `image` is any `t:Vimage.t/0`

    * `source` is a list of four 2-tuples representing the
      four corners of the subject-of-interest in `image`.

    * `destination` is a list of four 2-tuples representing the
      four corners of the destination image into which the
      subject-of-interest is transformed.

    ### Returns

    * `{:ok, transform_matrix}` or

    * `{:error, reason}`.

    """
    @doc subject: "Operation", since: "0.28.0"

    @spec transform_matrix(
            Vimage.t(),
            source :: quadrilateral(),
            destination :: quadrilateral()
          ) ::
            {:ok, transform_matrix :: Vimage.t()} | {:error, error_message()}

    def transform_matrix(image, source, destination) do
      with [{sx1, sy1}, {sx2, sy2}, {sx3, sy3}, {sx4, sy4}] <- source,
           [{dx1, dy1}, {dx2, dy2}, {dx3, dy3}, {dx4, dy4}] <- destination do
        source =
          Nx.tensor([
            [dx1, dy1, 1, 0, 0, 0, -dx1 * sx1, -dy1 * sx1],
            [dx2, dy2, 1, 0, 0, 0, -dx2 * sx2, -dy2 * sx2],
            [dx3, dy3, 1, 0, 0, 0, -dx3 * sx3, -dy3 * sx3],
            [dx4, dy4, 1, 0, 0, 0, -dx4 * sx4, -dy4 * sx4],
            [0, 0, 0, dx1, dy1, 1, -dx1 * sy1, -dy1 * sy1],
            [0, 0, 0, dx2, dy2, 1, -dx2 * sy2, -dy2 * sy2],
            [0, 0, 0, dx3, dy3, 1, -dx3 * sy3, -dy3 * sy3],
            [0, 0, 0, dx4, dy4, 1, -dx4 * sy4, -dy4 * sy4]
          ])

        destination = Nx.tensor([sx1, sx2, sx3, sx4, sy1, sy2, sy3, sy4])

        transform_matrix = Nx.LinAlg.solve(source, destination)
        {:ok, generate_map(Image.width(image), Image.height(image), transform_matrix)}
      else
        _error ->
          {:error,
           "Invalid source or destination quadrilateral. " <>
             "Found source #{inspect(source)} and destination #{inspect(destination)}."}
      end
    end

    defp generate_map(width, height, tensor) do
      use Image.Math

      [t0, t1, t2, t3, t4, t5, t6, t7] = Nx.to_list(tensor)
      index = Operation.xyz!(width, height)

      x =
        (
          t = index * [t0, t1]
          x_a = t[0] + t[1] + t2

          t = index * [t6, t7]
          x_b = t[0] + t[1] + 1

          x_a / x_b
        )

      y =
        (
          t = index * [t3, t4]
          y_a = t[0] + t[1] + t5

          t = index * [t6, t7]
          y_b = t[0] + t[1] + 1

          y_a / y_b
        )

      Vix.Vips.Operation.bandjoin!([x, y])
    end

    # TODO Needs to respect the image type when doing the
    # color channel order conversion (ie when its an RGB-A etc etc)
    # Same for interpretation (not every image is srgb!)

    if Code.ensure_loaded?(Evision) do
      @doc """
      Converts an `Image` image to an [Evision]() image.

      Note that only images with 3 bands can be transferred
      to `eVision`.

      ### Arguments

      * `image` is any `t:Vimage.t/0`

      * `convert_to_bgr` is a boolean indicating if the
        color order should be converted from `RGB` to `BGR`
        which is the normal channel layout for OpenCV. The
        default is `true`.

      ### Returns

      * `{:ok, evision_image}`

      ### Notes

      * `Image` images have the shape `{width, height, bands}`
        whereas `Evision` images have the shape `{height, width, bands}`
        so this function transposes the dimensions to match.

      * `Image` data is arranged as `rgb` data elements whereas
        `Evision` requires the data to be in `bgr` order. This function
        also reorders the data appropriately.

      """
      @dialyzer {:nowarn_function, {:to_evision, 2}}

      @doc subject: "Matrix", since: "0.9.0"

      def to_evision(%Vimage{} = image, convert_to_bgr \\ true) do
        with {:ok, tensor} <- to_nx(image),
             {width, height, bands} <- validate_transferable_image(image),
             %Evision.Mat{} = mat <- Evision.Mat.from_nx(tensor, {height, width, bands}),
             %Evision.Mat{} = mat <- Evision.Mat.last_dim_as_channel(mat) do
          mat =
            if convert_to_bgr,
              do: Evision.cvtColor(mat, Evision.Constant.cv_COLOR_RGB2BGR()),
              else: mat

          {:ok, mat}
        end
      end

      @doc """
      Converts to an `Image` image from an `Evision.Mat` image.

      ### Arguments

      * `evision_image` is any `Evision.Mat` image.

      ### Returns

      * `{:ok, image}`

      ### Notes

      * `Image` images have the shape `{width, height, bands}`
        whereas `Evision` images have the shape `{height, width, bands}`
        so this function transposes the dimensions to match.

      * `Image` data is arranged as `rgb` data elements whereas
        `Evision` requires the data to be in `bgr` order. This function
        also reorders the data appropriately.

      """
      @dialyzer {:nowarn_function, {:from_evision, 1}}

      @doc subject: "Matrix", since: "0.9.0"

      def from_evision(%Evision.Mat{} = evision_image) do
        with %Evision.Mat{} = mat <-
               Evision.cvtColor(evision_image, Evision.Constant.cv_COLOR_BGR2RGB()) do
          tensor = Evision.Mat.to_nx(mat)

          case Nx.shape(tensor) do
            {x, y, bands} when bands in 1..5 ->
              {width, height} = dimensions_from_tensor(tensor, x, y)

              tensor
              |> Nx.reshape({width, height, bands}, names: [:height, :width, :bands])
              |> from_nx()

            shape ->
              shape_error(shape)
          end
        end
      end
    end
  end

  @doc """
  Applies a transformation matrix to an image.

  A transformation matrix is returned by
  `Image.transform_matrix/3`.

  `Image.warp_perspective/4` uses this function to
  apply a perspective transform to an image.

  ### Arguments

  * `image` is any `t:Vimage.t/0`

  * `transform_matrix` is a matrix returned by
    `Image.transform_matrix/3`.

  ### Returns

  * `{:ok, mapped_image}` or

  * `{:error, reason}`

  """
  @doc subject: "Operation", since: "0.28.0"

  @spec map(Vimage.t(), Vimage.t(), Keyword.t()) :: {:ok, Vimage.t()} | {:error, error_message()}
  def map(%Vimage{} = image, %Vimage{} = transformation_matrix, options \\ []) do
    with {:ok, options} <- Options.WarpPerspective.validate_options(image, options) do
      Operation.mapim(image, transformation_matrix, options)
    end
  end

  @doc """
  Compare two images using a particular comparison metric
  returning a score indicating the similarity of the images.

  ### Arguments

  * `image_1` is any `t:Vix.Vips.Image.t/0`.

  * `image_2` is any `t:Vix.Vips.Image.t/0`.

  * `options` is a keyword list of options.

  ### Options

  * `:metric` indicates which comparison metric to use. The default
    is `:ae`. The valid metrics are:

    * [:ae](https://en.wikipedia.org/wiki/Sum_of_absolute_differences) which returns
      the absolute nuber of pixels that are different between the two images.
      The returned value is conformed to the range of the underlying image format.
      Therefore the returned value is between `0.0` (images appear to be the same)
      and `1.0` (meaning the images appear completely different).

    * [:rmse](https://en.wikipedia.org/wiki/Root-mean-square_deviation) is the root
      mean square error. The returned value is conformed to the range of
      the underlying image format. Therefore the returned value is between `0.0`
      (images appear to be the same) and `1.0` (meaning the images appear
      completely different),

    * [:mse](https://en.wikipedia.org/wiki/Mean_squared_error) which
      is the mean squared error (default). The returned value is a float
      indicating how similar the images are. A value of
      `0.0` means the images are the same. The number itself it simply a
      measure of the error difference between images. A larger number means
      the two images are less similar but the number itself cannot be
      interpreted as a percentage value.

  * `:difference_color` is the color to be used for the pixels that are
    different between the two images. This can be specified as a single integer
    which will be applied to all bands, or a list of integers representing
    he color for each band. The color can also be supplied as a
    CSS color name as a string or atom. For example: `:misty_rose`.
    It can also be supplied as a hex string of the form `#rrggbb`. The default
    is `:red`.

  * `:difference_boost` is a float multiplier that is applied to the difference
    image. This has the effect of boosting the overall brightness of the difference
    pixels making them stand out more against the background image. The default
    is `1.5`.

  * `:saturation` is a float between `0.0` and `1.0` that is applied to the
    base image when overlaying the difference image. This may help the difference
    pixels become more obvious. The default ia `1.0` meaning no change in
    saturation.

  * `:brightness` is a float between `0.0` and `1.0` that is applied to the
    base image when overlaying the difference image. This may help the difference
    pixels become more obvious. The default ia `1.0` meaning no change in
    brightness.

  ### Notes

  * The images are conformed to the band format of the
    first image before comparison and cast up to the smallest common
    format.

  * If the images differ in size, the smaller image is enlarged
    to match the larger by adding zero pixels along the bottom and right.

  * If the number of bands differs, one of the images must have one band.
    In this case, an n-band image is formed from the one-band image by joining
    `n` copies of the one-band image together, and then the two n-band images
    are operated upon.

  * The two input images are cast up to the smallest common format.

  ### Returns

  * `{:ok, comparison_score}` or

  * `{:error, reason}`

  """
  @doc since: "0.34.0"
  @doc subject: "Operation"

  @spec compare(Vimage.t(), Vimage.t(), Keyword.t()) ::
          {:ok, number, Vimage.t()} | {:error, error_message()}
  def compare(%Vimage{} = image_1, %Vimage{} = image_2, options \\ []) when is_list(options) do
    with {:ok, options} <- Options.Compare.validate_options(options),
         {:ok, image_1} <- Image.flatten(image_1),
         {:ok, image_2} <- Image.flatten(image_2),
         {:ok, difference} <- image_difference(image_1, image_2),
         {:ok, metric} <- compare_by_metric(image_1, image_2, difference, options.metric),
         {:ok, composed_difference} <- compose_difference(image_1, difference, options) do
      {:ok, metric, composed_difference}
    end
  end

  @dialyzer {:nowarn_function, {:compare_by_metric, 4}}

  # Mean square error
  # mse = ((a - b) ** 2).avg()

  defp compare_by_metric(_image_1, _image_2, difference, :mse) do
    difference
    |> Math.pow!(2)
    |> Operation.avg()
  end

  # Root mean square error, fit to the range of
  # the band format and therefore in the range 0.0 to 1.0
  defp compare_by_metric(image_1, image_2, diff, :rmse) do
    with {:ok, mse} <- compare_by_metric(image_1, image_2, diff, :mse),
         {:ok, format_size} <- format_size(image_1) do
      rmse =
        mse
        |> :math.sqrt()
        |> Kernel./(format_size)

      {:ok, rmse}
    end
  end

  # Absolute error. Count the number of pixels that are
  # different between the two images forced into a 0,0 to
  # 1.0 range

  defp compare_by_metric(image_1, image_2, difference, :ae) do
    with {:ok, non_zero} <- Image.Math.not_equal(difference, 0),
         {:ok, binary} <- Vimage.write_to_binary(non_zero[0]),
         {:ok, non_zero_pixel_count} <- non_zero_pixel_count(binary) do
      image_1_size = Image.width(image_1) * Image.height(image_1)
      image_2_size = Image.width(image_2) * Image.height(image_2)

      {:ok, non_zero_pixel_count / max(image_1_size, image_2_size)}
    end
  end

  defp compare_by_metric(_image_1, _image_2, _difference, metric) do
    {:error, "Invalid metric #{inspect(metric)}. Value metrics are :ae, :mse and :rmse"}
  end

  defp image_difference(image_1, image_2) do
    with {:ok, image_2} <- Operation.cast(image_2, Vix.Vips.Image.format(image_1)),
         {:ok, difference} <- Image.Math.subtract(image_1, image_2) do
      Operation.abs(difference)
    end
  end

  defp compose_difference(image, difference, options) do
    with {:ok, color_difference} <-
           if_then_else(difference, options.difference_color, :transparent),
         {:ok, color_difference} <-
           Image.Math.multiply(color_difference, options.difference_boost),
         {:ok, bw_difference} <- to_colorspace(difference, :bw),
         {:ok, alpha_difference} <- add_alpha(color_difference, bw_difference),
         {:ok, saturated} <- saturation(image, options.saturation),
         {:ok, brightened} <- brightness(saturated, options.brightness),
         {:ok, composed} <- compose(brightened, alpha_difference) do
      Operation.cast(composed, Vix.Vips.Image.format(image))
    end
  end

  @dialyzer {:nowarn_function, {:format_size, 1}}

  defp format_size(image) do
    case Image.BandFormat.nx_format(image) do
      {:ok, {:u, size}} -> {:ok, round(:math.pow(2, size))}
      {:ok, {:f, size}} -> {:ok, round(:math.pow(2, trunc(size)))}
    end
  end

  defp non_zero_pixel_count(binary) do
    count_of_different_pixels =
      for <<byte::integer-8-native <- binary>>, byte != 0, reduce: 0 do
        acc -> acc + 1
      end

    {:ok, count_of_different_pixels}
  end

  @doc """
  Returns a 64-bit (for a has size of the default 64) difference hash as a
  binary.

  Image hashes can be used to compare the similarity
  of images. See `Image.hamming_distance/2`.

  dhash is generates a "difference hash" for a given image. This
  is a perceptual hash based on Neal Krawetz's dHash algorithm in
  a [Hacker Factor](http://www.hackerfactor.com/blog/index.php?/archives/529-Kind-of-Like-That.html)
  blog entry.

  The code is adapted from the Ruby implementation in
  [dhash-vips](https://github.com/Nakilon/dhash-vips).

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `hash_size` is the size in bits of the returned hash.
    The default is `64`. The returned binary is only
    guaranteed to be the provided size if `sqrt(hash_size)` is
    an integer.

  ### Returns

  * `{:ok, 64-bit binary}` or

  * `{:error, reason}`

  """
  @dialyzer {:nowarn_function, {:dhash, 1}}
  @dialyzer {:nowarn_function, {:dhash, 2}}

  @doc subject: "Metadata", since: "0.6.0"

  @spec dhash(image :: Vimage.t(), hash_size :: pos_integer()) :: image_hash()
  def dhash(%Vimage{} = image, hash_size \\ 64) when is_integer(hash_size) and hash_size > 0 do
    alias Image.Math

    hash_size = round(:math.sqrt(hash_size))

    with {:ok, convolution} <- Image.Matrix.image_from_matrix([[1, -1]]),
         {:ok, pixels} <- dhash_pixels(image, convolution, hash_size) do
      dhash = for <<_::7, v::1 <- pixels>>, into: <<>>, do: <<v::1>>
      {:ok, dhash}
    end
  end

  def dhash_pixels(image, convolution, hash_size) do
    image
    |> pixelate_for_hash(hash_size)
    |> Operation.cast!(:VIPS_FORMAT_INT)
    |> Operation.conv!(convolution)
    |> crop!(1, 0, hash_size, hash_size)
    |> Math.greater_than!(0)
    |> Math.divide!(255)
    |> Operation.cast!(:VIPS_FORMAT_UCHAR)
    |> Vimage.write_to_binary()
  end

  defp pixelate_for_hash(%Vimage{} = image, hash_size) do
    image
    |> thumbnail!(hash_size + 1, height: hash_size, resize: :force)
    |> Operation.flatten!()
    |> to_colorspace!(:bw)
    |> Operation.extract_band!(0)
  end

  @doc false
  def convert_binary_to_hash(binary) do
    for <<byte::integer-8-native <- binary>>, reduce: <<>> do
      acc ->
        <<_rest::bitstring-7, bit::bitstring>> = <<byte::integer-8-native>>
        <<acc::bitstring, bit::bitstring>>
    end
  end

  @doc """
  Returns the hamming distance of two images
  or two image hashes.

  A [hamming distance](https://en.wikipedia.org/wiki/Hamming_distance)
  gives an indication of the similarity of two images.

  In general, a hamming distance of less than `10` indicates
  that the images are very similar.  A distance of
  less than `20` suggests the images are quite similar. Any
  other distance suggests the images have little in common.

  ### Arguments

  * `image_1` is any `t:Vix.Vips.Image.t/0`.

  * `image_2` is any `t:Vix.Vips.Image.t/0`.

  Alternatively, both arguments may be image hashes
  returned by `Image.dhash/1`. Both arguments must
  be of the same type.

  ### Returns

  * `{:ok, hamming_distance}` where hamming distance is
    a positive integer or

  * `{:error, reason}`.

  """
  @doc subject: "Operation", since: "0.6.0"

  @spec hamming_distance(image_1 :: Vimage.t(), image_2 :: Vimage.t(), hash_size :: pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, error_message()}

  def hamming_distance(image_1, image_2, hash_size \\ 64)

  def hamming_distance(%Vimage{} = image_1, %Vimage{} = image_2, hash_size)
      when is_integer(hash_size) and hash_size > 0 do
    with {:ok, hash_1} <- dhash(image_1, hash_size),
         {:ok, hash_2} <- dhash(image_2, hash_size) do
      hamming_distance(hash_1, hash_2)
    end
  end

  @spec hamming_distance(image_hash(), image_hash()) ::
          {:ok, non_neg_integer()} | {:error, error_message()}

  def hamming_distance(hash_1, hash_2, hash_size)
      when is_binary(hash_1) and is_binary(hash_2) and is_integer(hash_size) and hash_size > 0 do
    hash_1
    |> :crypto.exor(hash_2)
    |> count_ones()
    |> wrap(:ok)
  end

  defp count_ones(binary) when is_binary(binary) do
    for(<<bit::1 <- binary>>, do: bit) |> Enum.sum()
  end

  # Prebuilt binaries may not have this function because
  # libvips may not have the dependencies required.

  if Code.ensure_loaded?(Vix.Vips.Operation) && function_exported?(Vix.Vips.Operation, :fwfft!, 1) do
    @doc """
    Returns the fast fourier transform (fft) of
    the given image.

    ### Arguments

    * `image` is any `t:Vix.Vips.Image.t/0`.

    ### Returns

    * `{:ok, fft_image}` or

    * `{:error, reason}`

    ### Example

        Image.fft(image)

    """
    @doc subject: "Operation"

    @spec fft(Vimage.t()) :: {:ok, Vimage.t()} | {:error, error_message()}
    def fft(%Vimage{} = image) do
      image
      |> to_colorspace!(:bw)
      |> Operation.fwfft!()
      |> Operation.wrap!()
      |> Operation.abs()
    end

    @doc """
    Returns the fast fourier transform (fft) of
    the given image returning an image or
    raising an exception.

    ### Arguments

    * `image` is any `t:Vix.Vips.Image.t/0`.

    ### Returns

    * `fft_image` or

    * raises an exception

    ### Example

        Image.fft!(image)

    """
    @doc subject: "Operation"

    @spec fft!(Vimage.t()) :: Vimage.t() | no_return()
    def fft!(%Vimage{} = image) do
      case fft(image) do
        {:ok, image} -> image
        {:error, reason} -> raise Image.Error, reason
      end
    end

    @doc """
    Attempts top determine the distance
    from the perpendicular for a given image.

    The principle is that rotating the image
    by the skew angle should return an image
    in the upright position.

    The results are very image sensitive and
    perfect results are not guaranteed.

    The algorithm is an implementation of
    [this stackoverflow post](https://stackoverflow.com/questions/52474645/improve-a-picture-to-detect-the-characters-within-an-area/52502597#52502597).

    ### Arguments

    * `image` is any `t:Vix.Vips.Image.t/0`.

    ### Returns

    * `skew_angle` which is a float number
      of degrees the image is tilted from the
      upright.

    #### Example

        skew_angle = skew_angle(image)
        Image.rotate(image, skew_angle)

    """
    @dialyzer {:nowarn_function, {:skew_angle, 1}}
    @doc subject: "Operation"

    @spec skew_angle(Vimage.t()) :: float()

    def skew_angle(%Vimage{} = image) do
      {_columns, rows} =
        image
        |> fft!()
        |> to_rectangular_coordinates!()
        |> Operation.project!()

      {_v, _x, y} =
        rows
        |> Operation.gaussblur!(10.0)
        |> Image.Math.maxpos()

      # and turn to an angle in degrees we should counter-rotate by
      270 - 360 * y / height(rows)
    end
  end

  @doc """
  Convert an image into a mask.

  Takes an image, extracts its alpha channel
  which holds the opacity information and
  inverts the content.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * `{:ok, mask}` or

  * `{:error, reason}`

  """
  @doc subject: "Mask"

  @spec convert_to_mask(Vimage.t()) :: {:ok, Vimage.t()} | {:error, error_message()}
  def convert_to_mask(%Vimage{} = image) do
    if alpha_band = alpha_band(image) do
      {:ok, mask} = Operation.extract_band(image, alpha_band)
      Operation.invert(mask)
    else
      {:error, "Image has no alpha band"}
    end
  end

  @doc """
  Convert an image into a mask returning
  an image or raising an exception.

  Takes an image, extracts its alpha channel
  which holds the opacity information and
  inverts the content.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * `mask` image or

  * raises an exception

  """
  @doc subject: "Mask"

  @spec convert_to_mask!(Vimage.t()) :: Vimage.t() | no_return()
  def convert_to_mask!(%Vimage{} = image) do
    case convert_to_mask(image) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Split the image into a list of its component
  bands.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * a list of single band images extracted
    from `image`.

  """
  @doc subject: "Split and join", since: "0.13.0"

  @spec split_bands(Vimage.t()) :: [Vimage.t()]
  def split_bands(%Vimage{} = image) do
    for i <- 0..max_band_index(image), do: image[i]
  end

  @doc """
  Returns a boolean based upon whether a given
  image has an alpha band.

  The determination is a heuristic so certainty
  cannot be guaranteed.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * `true` or `false`

  ### Examples

      iex> image = Image.open!("./test/support/images/image_with_alpha2.png")
      iex> Image.has_alpha?(image)
      true

      iex> image = Image.open!("./test/support/images/Kamchatka-2019-8754.jpg")
      iex> Image.has_alpha?(image)
      false

  """
  @doc subject: "Image info"

  @spec has_alpha?(Vimage.t()) :: boolean()
  def has_alpha?(%Vimage{} = image) do
    Vimage.has_alpha?(image)
  end

  @doc """
  Returns the band number of the alpha
  channel of an image, or nil if it doesn't
  have one.

  The determination is a heuristic so certainty
  cannot be guaranteed.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * An integer in the range `1..4` depending
    on the image interpretation. Returns `nil`
    if there is no alpha band. The integer
    is a 0-based offset and can therefore be
    directly used to access the band. For example
    `image[alpha_band(image)]`.

  """
  @doc subject: "Split and join"

  @spec alpha_band(Vimage.t()) :: 1..4 | nil
  def alpha_band(%Vimage{} = image) do
    if has_alpha?(image) do
      Vimage.bands(image) - 1
    else
      nil
    end
  end

  @doc """
  Casts an image from one band format to another.

  The band format is the numeric type of each pixel.
  In the common case of `sRGB` images, the format is
  `{:u, 8}` meaning unsigned 8-bit values.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `band_format` is any known band format. See
    `Image.BandFormat.known_band_formats/0`.

  ### Returns

  * `{:ok, cast_image}` or

  * `{:error, reason}`.

  """
  @doc since: "0.30.0", subject: "Operation"

  @spec cast(Vimage.t(), BandFormat.t()) :: {:ok, Vimage.t()} | {:error, error_message()}
  def cast(%Vimage{} = image, band_format) do
    with {:ok, band_format} <- BandFormat.validate(band_format) do
      Operation.cast(image, band_format)
    end
  end

  @doc """
  Execute a function over the image without
  its alpha band (if any) ensuring the alpha
  band is replaced when the function returns.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `fun` is any 1-arity function that is
    required to return `{:ok, image}` or
    `{:error, reason}`.

  ### Returns

  * `{:ok, image}` or

  * `{:error, reason}`.

  """
  @doc since: "0.29.0", subject: "Operation"

  @spec without_alpha_band(
          Vimage.t(),
          (Vimage.t() -> {:ok, Vimage.t()} | {:error, error_message})
        ) ::
          {:ok, Vimage.t()} | {:error, error_message}

  def without_alpha_band(%Vimage{} = image, fun) when is_function(fun, 1) do
    {without_alpha, alpha} = split_alpha(image)

    case fun.(without_alpha) do
      {:ok, image} -> {:ok, bandjoin!(image, alpha)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Execute a function over the image casting it
  first to a color space and ensuring the color
  space conversion is reverted when the function
  returns.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `colorspace` is any valid color space.
    See `Image.Interpretation.known_interpretations/0`.

  * `fun` is any 1-arity function that is
    required to return `{:ok, image}` or
    `{:error, reason}`.

  ### Returns

  * `{:ok, image}` or

  * `{:error, reason}`.

  """
  @doc since: "0.29.0", subject: "Operation"

  @spec with_colorspace(
          Vimage.t(),
          colorspace :: Interpretation.t(),
          (Vimage.t() -> {:ok, Vimage.t()} | {:error, error_message})
        ) ::
          {:ok, Vimage.t()} | {:error, error_message}

  def with_colorspace(image, colorspace, fun) do
    original_colorspace = interpretation(image)

    with {:ok, converted} <- to_colorspace(image, colorspace) do
      case fun.(converted) do
        {:ok, image} -> to_colorspace(image, original_colorspace)
        other -> other
      end
    end
  end

  @doc """
  Execute a function over the image casting it
  first to a different band format and ensuring the band
  format reverted when the function returns.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `band_format` is any valid band format.
    See `Image.BandFormat.known_band_formats/0`.

  * `fun` is any 1-arity function that is
    required to return `{:ok, image}` or
    `{:error, reason}`.

  ### Returns

  * `{:ok, image}` or

  * `{:error, reason}`.

  ### Example

      iex> image = Image.open!("./test/support/images/Singapore-2016-09-5887.jpg")
      iex> {:ok, updated_image} = Image.with_band_format(image, {:s, 16}, fn i -> {:ok, i} end)
      iex> Image.band_format(updated_image)
      {:u, 8}

  """
  @doc since: "0.35.0", subject: "Operation"

  @spec with_band_format(
          Vimage.t(),
          band_format :: BandFormat.t(),
          (Vimage.t() -> {:ok, Vimage.t()} | {:error, error_message})
        ) ::
          {:ok, Vimage.t()} | {:error, error_message}

  def with_band_format(image, band_format, fun) do
    original_band_format = band_format(image)

    with {:ok, converted} <- cast(image, band_format) do
      case fun.(converted) do
        {:ok, image} -> cast(image, original_band_format)
        other -> other
      end
    end
  end

  @doc """
  For each page of an image, execute `fun/1` then
  reassemble the pages.

  If the function is successful for each page,
  assemble the new pages (returned from `fun/1`)
  into a new image.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0` in `.gif`
     or `.png` multi-page format.

  * `fun` is any 1-arity function that takes a
    page as a `t:Vix.Vips.Image.t/0` as its argument
    and is required to return either `{:ok, new_page_image}`
    or `{:error, reason}` as its return value.

  ### Returns

  * `{:ok, mapped_image}` where all the new pages returned
    from `fun/1` are assembled into `mapped_image` or

  * `{:error, reason}`.

  ### Examples

      # The option `pages: -1` means load all the pages of a multi-page image.
      iex> image = Image.open!("./test/support/images/animated.webp", pages: :all)
      iex> {:ok, _mapped_image} = Image.map_pages(image, &Image.equalize/1)

      # Also works for .gif images
      iex> image = Image.open!("./test/support/images/animated.gif", pages: :all)
      iex> {:ok, _mapped_image} = Image.map_pages(image, &Image.equalize/1)

      # If an image isn't opened with `pages: :all` then only
      # the first page of an image is loaded.
      iex> image_2 = Image.open!("./test/support/images/animated.webp")
      iex> Image.map_pages(image_2, &Image.equalize/1)
      {:error, "Image does not have a page-height header. " <>
        "Perhaps the image wasn't opened with the `pages: :all` option or " <>
        "libvips wasn't built with libwebp-dev/libgif-dev configured? " <>
        "Run `vips --vips-config` from the command line to check."}

  """
  @doc since: "0.38.0", subject: "Operation"

  @spec map_pages(Vimage.t(), (Vimage.t() -> {:ok, Vimage.t()} | {:error, error_message()})) ::
    {:ok, Vimage.t()} | {:error, error_message()}

  def map_pages(%Vimage{} = image, fun) when is_function(fun, 1) do
    map_pages(image, fun, pages(image))
  end

  # There is only one page - a normal image
  # So just invoke the given function.

  defp map_pages(image, fun, 1) do
    fun.(image)
  end

  # The image has multiple pages. We need to split the
  # image, process and reassemble. Then we need to set the
  # `page-height` of the new image.

  defp map_pages(image, fun, pages) do
    with {:ok, page_height} <- page_height(image),
         {:ok, new_pages} <- reduce_pages(image, pages, page_height, fun),
         {:ok, new_image} <- join(Enum.reverse(new_pages)) do
       new_page_height = Image.height(hd(new_pages))

       case Image.mutate(new_image, &MutableImage.set(&1, "page-height", :gint, new_page_height)) do
         {:ok, updated_image} ->
           {:ok, updated_image}

         {:error, reason} ->
           {:error, "Could not set the page-height header. Reason: #{inspect reason}"}
       end
    end
  end

  defp join(pages) do
    case Operation.arrayjoin(pages, across: 1) do
      {:ok, image} ->
        {:ok, image}

      {:error, reason} ->
        {:error, "Could not join the pages into a new image. Reason: #{inspect reason}"}
    end
  end

  defp page_height(image) do
    case Vix.Vips.Image.header_value(image, "page-height") do
      {:ok, page_height} ->
        {:ok, page_height}

      {:error, _reason} ->
        {:error, "Image does not have a page-height header. " <>
          "Perhaps the image wasn't opened with the `pages: :all` option or " <>
          "libvips wasn't built with libwebp-dev/libgif-dev configured? " <>
          "Run `vips --vips-config` from the command line to check."}
    end
  end

  defp reduce_pages(image, pages, page_height, fun) do
    width = width(image)

    Enum.reduce_while(1..pages, {:ok, []}, fn n, {:ok, acc} ->
      {:ok, page_n} = Operation.extract_area(image, 0, page_height * (n - 1), width, page_height)

      case fun.(page_n) do
        {:ok, new_page_n} -> {:cont, {:ok, [new_page_n | acc]}}
        {:error, reason} -> {:halt, {:error, "Page #{n} returned #{inspect reason}"}}
      end
    end)
  end

  # The iTerm2 Image Preview protocol is:
  # ESC ] 1337 ; File = [arguments] : base-64 encoded file contents ^G

  # Decimal 27
  @esc <<0x1B>>
  # Decimal 7
  @ctrl_g <<0x07>>

  @default_max_width "1000"
  @max_width_env_key "IMAGE_PREVIEW_MAX_WIDTH"

  @doc """
  Outputs an inline preview of an image to
  an iTerm2 terminal.

  Only iTerm2 terminal windows are supported.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0` or
    a tuple of the form `{:ok, image}`.

  ### Returns

  * The `image` parameter as provided with the
    side effect of emitting an image preview on
    an iTerm terminal.

  ### Notes

  * The function `Image.p/1` is delegated to
    this function.

  * The maximum width of the preview can be set
    by the environment variable `#{@max_width_env_key}`.
    The default is `1_000` pixels wide. If the width
    of the image is greater than the maximum it will be
    resized to the maximum width for the preview.

  * Intended to be used as shortcut in `iex`.
    It can be included in an `.iex.exs` file:

      # .iex.exs
      import_if_available(Image, only: [preview: 1])

  """
  @doc subject: "Display", since: "0.13.0"

  @spec preview(Vimage.t() | {:ok, Vimage.t()}) ::
          Vimage.t() | {:ok, Vimage.t()} | {:error, error_message()}

  def preview(%Vimage{} = image) do
    with {:ok, "iTerm2"} <- supported_terminal(System.get_env("LC_TERMINAL")) do
      {prelude, epilog} = get_prelude_epilog_for_term(System.get_env("TERM"))
      {:ok, image} = maybe_resize_to_fit(image, shape(image))

      with {:ok, binary} <- Vix.Vips.Image.write_to_buffer(image, ".png") do
        encoded_image = Base.encode64(binary, padding: true)
        bin_size = byte_size(binary)
        head = prelude <> "]1337;File=size=#{bin_size};inline=1:"
        IO.write(head <> encoded_image <> epilog)
        image
      end
    end
  end

  def preview({:ok, %Vimage{} = image}) do
    {:ok, preview(image)}
  end

  @doc """
  Outputs an inline preview of an image to
  an iTerm2 terminal.

  Only iTerm2 terminal windows are supported.

  Delegates to `Image.preview/1`

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Notes

  * The function `Image.p/1` is delegated to
    this function.

  * The maximum width of the preview can be set
    by the environment variable `#{@max_width_env_key}`.
    The default is `1_000` pixels wide. If the width
    of the image is greater than the maximum it will be
    resized to the maximum width for the preview.

  * Intended to be used as shortcut in `iex`.
    It can be included in `.iex.exs` file:

      # .iex.exs
      import_if_available(Image, only: [p: 1])

  """
  @doc subject: "Display", since: "0.13.0"

  @spec p(Vimage.t()) :: Vimage.t() | {:error, error_message()}
  def p(image) do
    preview(image)
  end

  defp supported_terminal("iTerm2" = terminal) do
    {:ok, terminal}
  end

  defp supported_terminal(terminal) do
    {:error,
     "Unsupported terminal #{inspect(terminal)}. iTerm2 is required for inline image display."}
  end

  defp get_prelude_epilog_for_term("screen" <> _rest) do
    {@esc <> "Ptmux;" <> @esc <> @esc, @ctrl_g <> @ctrl_g <> "\\\r\n"}
  end

  defp get_prelude_epilog_for_term(_term) do
    {@esc, @esc <> "\\" <> "\r\n"}
  end

  defp maybe_resize_to_fit(image, {width, _height, _bands}) do
    max_width =
      @max_width_env_key
      |> System.get_env(@default_max_width)
      |> String.to_integer()

    if width > max_width do
      thumbnail(image, max_width)
    else
      {:ok, image}
    end
  end

  @doc """
  Returns the number of operating system
  threads available for use by `libvips`.

  By default the number of threads will be
  the number of cores in the system.

  Since image processing is CPU intensive it
  may be appropriate to reduce the number of
  threads to be available to reduce the risk
  of CPU starvation for other workloads.

  See `Image.put_concurrency/1`.

  """
  @doc subject: "Configuration"

  @spec get_concurrency :: pos_integer()
  def get_concurrency do
    Vix.Vips.concurrency_get()
  end

  @doc """
  Sets the number of available threads for use
  by `libvips`.

  By default this is the same as the number of
  cores in the system. Reducing this number may
  prevent CPU starvation for other workloads.

  ### Arguments

  * `concurrency` is a positive integer denoting
    the maximum number of threads that `libvips` will
    use for concurrency.

  ### Returns

  * `{:ok, updated_concurrency}`

  """
  @doc subject: "Configuration"

  @spec put_concurrency(pos_integer()) :: pos_integer()
  def put_concurrency(concurrency) when is_integer(concurrency) and concurrency > 0 do
    :ok = Vix.Vips.concurrency_set(concurrency)
    get_concurrency()
  end

  @doc """
  Returns the aspect of an image.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`

  * `options` is a keyword list of options

  ### Options

  * `:square_ratio` indicates when an image
    is to be considered square. It is a floating
    point indicator of the ratio between the width
    and height below which the image is considered
    square. The default is `0.0` meaning that the
    dimensions must be exactly equal in order for
    the image to be considered square.

  ### Returns

  * Either `:landscape`, `:portrait` or `:square`.

  ### Example

      iex> puppy = Image.open!(Path.expand("test/support/images/puppy.webp"))
      iex> Image.aspect(puppy, square_ratio: 0.05)
      :landscape

  """
  @doc subject: "Image info"

  @spec aspect(Vimage.t()) :: aspect()
  def aspect(%Vimage{} = image, options \\ []) do
    square_ratio = Keyword.get(options, :square_ratio, @square_when_ratio_less_than)
    width = Image.width(image)
    height = Image.height(image)
    ratio = abs(1.0 - width / height)

    cond do
      ratio <= square_ratio -> :square
      width > height -> :landscape
      height > width -> :portrait
    end
  end

  @doc """
  Returns the version of `libvips` in
  operation.

  """
  @doc subject: "Configuration"

  @spec vips_version :: {:ok, Version.t()}
  def vips_version do
    Vix.Vips.version()
    |> Version.parse()
  end

  ### Helpers

  defp wrap(item, atom) do
    {atom, item}
  end

  defp build_option_string(options, other_options) do
    "[" <> options <> "," <> join_options(other_options) <> "]"
  end

  defp build_option_string(options) do
    "[" <> join_options(options) <> "]"
  end

  defp join_options(options) do
    Enum.map_join(options, ",", fn {k, v} -> "#{k}=#{v}" end)
  end

  defp file_exists?(path) do
    if File.exists?(path, [:raw]), do: {:ok, path}, else: {:error, :enoent}
  end

  defp xy_offset(%Vimage{} = _image, _overlay, x, y)
       when is_number(x) and is_number(y) and x >= 0 and y >= 0 do
    {x, y}
  end

  # Offset from the right of the image
  defp xy_offset(%Vimage{} = base_image, overlay, x, y) when is_number(x) and x < 0 do
    x = Image.width(base_image) - Image.width(overlay) + x
    xy_offset(base_image, overlay, x, y)
  end

  # Offset from the bottom of the image
  defp xy_offset(%Vimage{} = base_image, overlay, x, y) when is_number(y) and y < 0 do
    y = Image.height(base_image) - Image.height(overlay) + y
    xy_offset(base_image, overlay, x, y)
  end

  defp xy_offset(%Vimage{} = base_image, %Vimage{} = overlay, x, y)
       when is_number(x) and is_atom(y) do
    y = offset_from(y, Image.height(base_image), Image.height(overlay))
    {x, y}
  end

  defp xy_offset(%Vimage{} = base_image, %Vimage{} = overlay, x, y)
       when is_atom(x) and is_number(y) do
    x = offset_from(x, Image.width(base_image), Image.width(overlay))
    {x, y}
  end

  defp xy_offset(%Vimage{} = base_image, %Vimage{} = overlay, x, y) do
    x = offset_from(x, Image.width(base_image), Image.width(overlay))
    y = offset_from(y, Image.height(base_image), Image.height(overlay))
    {x, y}
  end

  # Used for x offset
  defp offset_from(:left, _base_size, _overlay_size), do: 0
  defp offset_from(:right, base_size, overlay_size), do: base_size - overlay_size
  defp offset_from(:center, base_size, overlay_size), do: div(base_size, 2) - div(overlay_size, 2)

  # Used for y offset
  defp offset_from(:top, _base_size, _overlay_size), do: 0
  defp offset_from(:bottom, base_size, overlay_size), do: base_size - overlay_size
  defp offset_from(:middle, base_size, overlay_size), do: div(base_size, 2) - div(overlay_size, 2)

  defp offset_from(other, _base_size, _overlay_size) do
    raise ArgumentError, """
    Invalid offset position #{inspect(other)}.
    Valid positions are :left, :right, :middle, :top, :bottom, :center
    """
  end

  @doc false
  def validate_transferable_image(image) do
    case shape(image) do
      {width, height, bands} when bands == 3 ->
        {width, height, bands}

      other ->
        {:error,
         "Only images with three bands can be transferred to eVision. " <>
           "Found an image of shape #{inspect(other)}"}
    end
  end

  @doc false
  def bumblebee_configured? do
    Enum.reduce_while([Nx, EXLA, Bumblebee], true, fn mod, flag ->
      case Code.ensure_compiled(mod) do
        {:module, _module} -> {:cont, flag}
        _other -> {:halt, false}
      end
    end)
  end

  @doc false
  def evision_configured? do
    match?({:module, _module}, Code.ensure_compiled(Evision))
  end
end
