(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2019 Savonet team

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
  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA

 *****************************************************************************)

(** FFMPEG encoder *)

open Ffmpeg_encoder_common

let () =
  Encoder.plug#register "FFMPEG" (function
    | Encoder.Ffmpeg m ->
        Some
          (fun _ ->
            let mk_audio =
              match m.Ffmpeg_format.audio_codec with
                | Some `Copy ->
                    let sample_time_base =
                      Ffmpeg_utils.liq_audio_sample_time_base ()
                    in
                    fun ~ffmpeg:_ ~options:_ ->
                      Ffmpeg_copy_encoder.mk_stream_copy ~sample_time_base
                        ~convert_pos:Frame.audio_of_master
                        ~get_data:(fun frame ->
                          Ffmpeg_content.AudioCopy.get_data
                            Frame.(frame.content.audio))
                | _ -> Ffmpeg_internal_encoder.mk_audio
            in
            let mk_video =
              match m.Ffmpeg_format.video_codec with
                | Some `Copy ->
                    let sample_time_base =
                      Ffmpeg_utils.liq_video_sample_time_base ()
                    in
                    fun ~ffmpeg:_ ~options:_ ->
                      Ffmpeg_copy_encoder.mk_stream_copy ~sample_time_base
                        ~convert_pos:Frame.video_of_master
                        ~get_data:(fun frame ->
                          Ffmpeg_content.VideoCopy.get_data
                            Frame.(frame.content.video))
                | _ -> Ffmpeg_internal_encoder.mk_video
            in
            encoder ~mk_audio ~mk_video m)
    | _ -> None)
