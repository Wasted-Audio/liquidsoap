(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2021 Savonet team

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

exception Read_error

(** Error translator *)
let error_translator e =
  match e with
    | Read_error -> Some "Error while reading http stream."
    | _ -> None

let () = Printexc.register_printer error_translator

(** Utility for reading icy metadata *)
let read_metadata () =
  let old_chunk = ref "" in
  fun socket ->
    let size =
      let buf = Bytes.of_string " " in
      let f : Http.connection -> Bytes.t -> int -> int -> int = Http.read in
      let s = f socket buf 0 1 in
      if s <> 1 then raise Read_error;
      int_of_char (Bytes.get buf 0)
    in
    let size = 16 * size in
    let chunk =
      let buf = Bytes.create size in
      let rec read pos =
        if pos = size then buf
        else (
          let p = Http.read socket buf pos (size - pos) in
          if p <= 0 then raise Read_error;
          read (pos + p) )
      in
      Bytes.unsafe_to_string (read 0)
    in
    let h = Hashtbl.create 10 in
    let rec parse s =
      try
        let mid = String.index s '=' in
        let close = String.index s ';' in
        let key = Configure.recode_tag (String.sub s 0 mid) in
        let value =
          Configure.recode_tag (String.sub s (mid + 2) (close - mid - 3))
        in
        let key =
          match key with
            | "StreamTitle" -> "title"
            | "StreamUrl" -> "url"
            | _ -> key
        in
        Hashtbl.add h key value;
        parse (String.sub s (close + 1) (String.length s - close - 1))
      with _ -> ()
    in
    if chunk = "" then None
    else if chunk = !old_chunk then None
    else (
      old_chunk := chunk;
      parse chunk;
      Some h )

(** HTTP input *)

module G = Generator
module Generator = Generator.From_audio_video_plus
module Generated = Generated.Make (Generator)

class http ~kind ~poll_delay ~track_on_meta ?(force_mime = None) ~bind_address
  ~autostart ~bufferize ~max ~timeout ~debug ~log_overfull ~on_connect
  ~on_disconnect ?(logfile = None) ~user_agent url =
  let max_ticks = Frame.main_of_seconds (Stdlib.max max bufferize) in
  (* We need a temporary log until the source has an ID. *)
  let log_ref = ref (fun _ -> ()) in
  let log x = !log_ref x in
  object (self)
    inherit Source.source ~name:"input.http" kind as super

    inherit
      Generated.source
        (Generator.create ~log ~log_overfull ~overfull:(`Drop_old max_ticks)
           `Undefined)
        ~empty_on_abort:false ~bufferize

    method stype = Source.Fallible

    (** [kill_polling] is for requesting that the feeding thread stops;
      * it is called on #sleep. *)
    val mutable kill_polling = None

    (** [wait_polling] is to make sure that the thread did stop;
      * it is only called in #wake_up before creating a new thread,
      * so that #sleep is instantaneous. *)
    val mutable wait_polling = None

    (** Log file for the timestamps of read events. *)
    val mutable logf = None

    val mutable relaying = autostart

    val mutable url = url

    method private relaying = self#mutexify (fun () -> relaying) ()

    method start_cmd = self#mutexify (fun () -> relaying <- true) ()

    method stop_cmd = self#mutexify (fun () -> relaying <- false) ()

    method set_url_cmd fn = self#mutexify (fun () -> url <- fn) ()

    method url_cmd = self#mutexify (fun () -> url ()) ()

    method status_cmd = self#mutexify (fun () -> "TODO") ()

    method buffer_length_cmd =
      self#mutexify (fun () -> Frame.seconds_of_audio self#length) ()

    (* Insert metadata *)
    method insert_metadata m =
      self#log#important "New metadata chunk: %s -- %s."
        (try Hashtbl.find m "artist" with _ -> "?")
        (try Hashtbl.find m "title" with _ -> "?");
      Generator.add_metadata generator m;
      if track_on_meta then Generator.add_break generator

    method decode ~url should_stop create_decoder =
      let c = Condition.create () in
      let m = Mutex.create () in
      let data = Buffer.create 1024 in
      let on_body_data =
        Tutils.mutexify m (fun s ->
            Buffer.add_string data s;
            Condition.signal c)
      in
      let read buf ofs len =
        Tutils.mutexify m
          (fun () ->
            let rec f () =
              match Buffer.length data with
                | 0 ->
                    Condition.wait c m;
                    f ()
                | n -> n
            in
            let ret = min (f ()) len in
            Buffer.blit data 0 buf ofs ret;
            Utils.buffer_drop data ret;
            ret)
          ()
      in
      ignore
        (Thread.create
           (fun () ->
             try
               ignore
                 (Liqcurl.http_request ~follow_redirect:true ~url ~request:`Get
                    ~on_body_data ())
             with exn ->
               let bt = Printexc.get_backtrace () in
               Utils.log_exception ~log:self#log ~bt (Printexc.to_string exn))
           ());
      let input = { Decoder.read; tell = None; length = None; lseek = None } in
      try
        let decoder = create_decoder input in
        let buffer = Decoder.mk_buffer ~ctype:self#ctype generator in
        while true do
          if should_fail then failwith "end of track";
          if should_stop () || not self#relaying then failwith "source stopped";
          decoder.Decoder.decode buffer
        done
      with e -> (
        if debug then raise e;

        (* Feeding has stopped: adding a break here. *)
        Generator.add_break ~sync:true generator;
        begin
          match e with
          | Failure s -> self#log#severe "Feeding stopped: %s" s
          | G.Incorrect_stream_type ->
              self#log#severe
                "Feeding stopped: the decoded stream was not of the right \
                 type. The typical situation is when you expect a stereo \
                 stream whereas the stream is mono (in this case the situation \
                 can easily be solved by using the audio_to_stereo operator to \
                 convert the stream to a stereo one)."
          | e -> self#log#severe "Feeding stopped: %s" (Printexc.to_string e)
        end;
        match logf with
          | Some f ->
              close_out f;
              logf <- None
          | None -> () )

    method private connect should_stop url =
      let content_type =
        match force_mime with
          | Some m -> m
          | None -> (
              let _, _, _, headers =
                Liqcurl.http_request ~follow_redirect:true ~timeout ~url
                  ~request:`Head
                  ~on_body_data:(fun _ -> ())
                  ()
              in
              match
                List.find_opt
                  (fun (lbl, _) -> String.lowercase_ascii lbl = "content-type")
                  headers
              with
                | Some (_, m) -> m
                | None -> "application/octet-stream" )
      in
      Generator.set_mode generator `Undefined;
      let dec =
        match Decoder.get_stream_decoder ~ctype:self#ctype content_type with
          | Some d -> d
          | None -> failwith "Unknown format!"
      in
      self#log#important "Decoding...";
      Generator.set_rewrite_metadata generator (fun m ->
          Hashtbl.add m "source_url" url;
          m);
      self#decode ~url should_stop dec

    (* Take care of (re)starting the decoding *)
    method feed (should_stop, has_stopped) =
      (* Try to read the stream *)
      let url = url () in
      if self#relaying then self#connect should_stop url;
      if should_stop () then has_stopped ()
      else (
        Thread.delay poll_delay;
        self#feed (should_stop, has_stopped) )

    method wake_up act =
      super#wake_up act;

      (* Now we can create the log function *)
      (log_ref := fun s -> self#log#important "%s" s);

      (* Wait for the old polling thread to return, then create a new one. *)
      assert (kill_polling = None);
      begin
        match wait_polling with
        | None -> ()
        | Some f ->
            f ();
            wait_polling <- None
      end;
      let kill, wait = Tutils.stoppable_thread self#feed "http feed" in
      kill_polling <- Some kill;
      wait_polling <- Some wait

    method sleep =
      (Option.get kill_polling) ();
      kill_polling <- None
  end

let () =
  Lang.add_operator "input.http" ~return_t:(Lang.univ_t ())
    ~meth:
      [
        ( "start",
          ([], Lang.fun_t [] Lang.unit_t),
          "Start reading input.",
          fun s ->
            Lang.val_fun [] (fun _ ->
                s#start_cmd;
                Lang.unit) );
        ( "stop",
          ([], Lang.fun_t [] Lang.unit_t),
          "Stop reading input.",
          fun s ->
            Lang.val_fun [] (fun _ ->
                s#stop_cmd;
                Lang.unit) );
        ( "url",
          ([], Lang.fun_t [] Lang.string_t),
          "URL of the input.",
          fun s -> Lang.val_fun [] (fun _ -> Lang.string s#url_cmd) );
        ( "set_url",
          ([], Lang.fun_t [(false, "", Lang.fun_t [] Lang.string_t)] Lang.unit_t),
          "Set the url of the input.",
          fun s ->
            Lang.val_fun [("", "", None)] (fun p ->
                let fn = List.assoc "" p in
                let fn () = Lang.to_string (Lang.apply fn []) in
                s#set_url_cmd fn;
                Lang.unit) );
        ( "status",
          ([], Lang.fun_t [] Lang.string_t),
          "Current status of the input.",
          fun s -> Lang.val_fun [] (fun _ -> Lang.string s#status_cmd) );
        ( "buffer_length",
          ([], Lang.fun_t [] Lang.float_t),
          "Length of the buffer length (in seconds).",
          fun s -> Lang.val_fun [] (fun _ -> Lang.float s#buffer_length_cmd) );
      ]
    ~category:Lang.Input ~descr:"Create a source that fetches a HTTP stream."
    [
      ( "autostart",
        Lang.bool_t,
        Some (Lang.bool true),
        Some "Initially start relaying or not." );
      ( "bind_address",
        Lang.string_t,
        Some (Lang.string ""),
        Some
          "Address to bind on the local machine. This option can be useful if \
           your machine is bound to multiple IPs. Empty means no bind address."
      );
      ( "buffer",
        Lang.float_t,
        Some (Lang.float 2.),
        Some "Duration of the pre-buffered data." );
      ( "timeout",
        Lang.int_t,
        Some (Lang.int 30),
        Some "Timeout for source connectionn." );
      ( "on_connect",
        Lang.fun_t [(false, "", Lang.metadata_t)] Lang.unit_t,
        Some (Lang.val_cst_fun [("", None)] Lang.unit),
        Some
          "Function to execute when a source is connected. Its receives the \
           list of headers, of the form: (<label>,<value>). All labels are \
           lowercase." );
      ( "on_disconnect",
        Lang.fun_t [] Lang.unit_t,
        Some (Lang.val_cst_fun [] Lang.unit),
        Some "Function to excecute when a source is disconnected" );
      ( "new_track_on_metadata",
        Lang.bool_t,
        Some (Lang.bool true),
        Some "Treat new metadata as new track." );
      ( "force_mime",
        Lang.string_t,
        Some (Lang.string ""),
        Some "Force mime data type. Not used if empty." );
      ( "poll_delay",
        Lang.float_t,
        Some (Lang.float 2.),
        Some "Polling delay when trying to connect to the stream." );
      ( "max",
        Lang.float_t,
        Some (Lang.float 20.),
        Some "Maximum duration of the buffered data." );
      ( "logfile",
        Lang.string_t,
        Some (Lang.string ""),
        Some
          "Log buffer status to file, for debugging purpose. Disabled if empty."
      );
      ( "debug",
        Lang.bool_t,
        Some (Lang.bool false),
        Some "Run in debugging mode, not catching some exceptions." );
      ( "log_overfull",
        Lang.bool_t,
        Some (Lang.bool true),
        Some "Log when the source's buffer is overfull." );
      ( "user_agent",
        Lang.string_t,
        Some (Lang.string Http.user_agent),
        Some "User agent." );
      ("", Lang.getter_t Lang.string_t, None, Some "URL of an HTTP stream");
    ]
    (fun p ->
      let url = Lang.to_string_getter (List.assoc "" p) in
      let autostart = Lang.to_bool (List.assoc "autostart" p) in
      let bind_address = Lang.to_string (List.assoc "bind_address" p) in
      let user_agent = Lang.to_string (List.assoc "user_agent" p) in
      let timeout = Lang.to_int (List.assoc "timeout" p) in
      let track_on_meta = Lang.to_bool (List.assoc "new_track_on_metadata" p) in
      let debug = Lang.to_bool (List.assoc "debug" p) in
      let log_overfull = Lang.to_bool (List.assoc "log_overfull" p) in
      let logfile =
        match Lang.to_string (List.assoc "logfile" p) with
          | "" -> None
          | s -> Some s
      in
      let bind_address = match bind_address with "" -> None | s -> Some s in
      let force_mime =
        match Lang.to_string (List.assoc "force_mime" p) with
          | "" -> None
          | s -> Some s
      in
      let bufferize = Lang.to_float (List.assoc "buffer" p) in
      let max = Lang.to_float (List.assoc "max" p) in
      if bufferize >= max then
        raise
          (Lang_errors.Invalid_value
             ( List.assoc "max" p,
               "Maximum buffering inferior to pre-buffered data" ));
      let on_connect l =
        let l =
          List.map
            (fun (x, y) -> Lang.product (Lang.string x) (Lang.string y))
            l
        in
        let arg = Lang.list l in
        ignore (Lang.apply (List.assoc "on_connect" p) [("", arg)])
      in
      let on_disconnect () =
        ignore (Lang.apply (List.assoc "on_disconnect" p) [])
      in
      let poll_delay = Lang.to_float (List.assoc "poll_delay" p) in
      let kind = Source.Kind.of_kind Lang.any in
      new http
        ~kind ~autostart ~track_on_meta ~force_mime ~bind_address ~poll_delay
        ~timeout ~on_connect ~on_disconnect ~bufferize ~max ~debug ~log_overfull
        ~logfile ~user_agent url)
