(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2013 Savonet team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details, fully stated in the COPYING
  file at the root of the liquidsoap distribution.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

 *****************************************************************************)

module Img = Image.RGBA32

let create_decoder metadata img =
  (* Dimensions. *)
  let fw, fh = Img.dimensions img in
  let width =
    try
      let w = int_of_string (Hashtbl.find metadata "width") in
      if w < 0 then fw else w
    with
    | Not_found -> fw
  in
  let height =
    try
      let h = int_of_string (Hashtbl.find metadata "height") in
      if h < 0 then fh else h
    with
    | Not_found -> fh
  in
  (* Offset. *)
  let off_x = try int_of_string (Hashtbl.find metadata "x") with Not_found -> 0 in
  let off_y = try int_of_string (Hashtbl.find metadata "y") with Not_found -> 0 in
  (* Negative offset means from the right. *)
  let off_x = if off_x < 0 then fw - width + off_x else off_x in
  let off_y = if off_y < 0 then fh - height + off_y else off_y in
  if (width,height) <> (fw,fh) || (off_x,off_y) <> (0,0) then
    (
      (* TODO: use Video_converter.find_converter *)
      let img' = Img.Scale.create img width height in
      Img.blank_all img;
      Img.add img' img ~x:off_x ~y:off_y
    );
  let duration =
    try
      let seconds = float_of_string (Hashtbl.find metadata "duration") in
      Frame.video_of_seconds seconds
    with
    | Not_found -> -1
  in
  let duration = ref duration in
  let close () = () in
  let fill frame =
    let video = (VFrame.content_of_type ~channels:1 frame).(0) in
    let start = VFrame.next_sample_position frame in
    let stop =
      if !duration = -1 then VFrame.size frame else
        min (VFrame.size frame) (start + !duration)
    in
    VFrame.add_break frame stop ;
    for i = start to stop-1 do
      (* One could think of avoiding the creation of a blank
       * video layer that will be overwritten immediately.
       * However, in most cases an old layer will be re-used.
       * In fact, we might even need to explicitly blankify
       * because our image might be transparent and the
       * current frame might contain random stuff. TODO *)
      Img.blit img video.(i)
    done ;
    if !duration = -1 then -1 else begin
      duration := !duration - (stop-start);
      Frame.master_of_video !duration
    end
  in
  { Decoder.
    fill = fill ;
    fseek = (fun _ -> 0);
    close = close }

let () =
  Decoder.file_decoders#register "Image"
    ~sdoc:"Decoder for static images."
    (fun ~metadata filename kind ->
      let ctype = { Frame. video = 1; audio = 0; midi = 0 } in
      try
        if not (Frame.type_has_kind ctype kind) then raise Exit;
        let img =
          match Decoder.get_image_file_decoder filename with
          | Some img -> img
          | None -> failwith "Could not decode image file."
        in
        Some (fun () -> create_decoder metadata img)
      with
      | _ -> None
    )

