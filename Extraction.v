(** Extraction of computations to OCaml. *)
Require Import Coq.Lists.List.
Require Import Coq.Strings.String.
Require Import Computation.
Require Import Pervasives.
Require Import StdLib.

Import ListNotations.
Open Local Scope string.

Module Native.
  Module String.
    Parameter t : Set.
    Extract Constant t => "string".

    Parameter append : t -> t -> t.

    Parameter to_string : t -> string.
    Parameter of_string : string -> t.

    Parameter to_nat : t -> option nat.
    Parameter of_nat : nat -> t.

    Parameter tokenize : t -> list t.
  End String.

  Module Base64.
    Parameter encode : String.t -> String.t.
    Parameter decode : String.t -> String.t.
  End Base64.

  Module Process.
    Parameter t : Set.
    Parameter run : String.t -> t.
    Parameter print_line : String.t -> t -> unit.
    Parameter fold_lines : forall A, t -> A -> (A -> String.t -> A) -> A.
  End Process.

  Parameter print_error : String.t -> unit.
End Native.

(** Import input events. *)
Module Input.
  Module Command.
    Inductive t : Set :=
    | file_read
    | tcp_client_socket_accepted | tcp_client_socket_read
    | tcp_server_socket_bound.

    Definition of_string (command : string) : option t :=
      if String.eqb command "File.read" then
        Some file_read
      else if String.eqb command "TCPClientSocket.accepted" then
        Some tcp_client_socket_accepted
      else if String.eqb command "TCPClientSocket.read" then
        Some tcp_client_socket_read
      else if String.eqb command "TCPServerSocket.bound" then
        Some tcp_server_socket_bound
      else
        None.
  End Command.

  Definition import_file_read (file_name : Native.String.t) (content : Native.String.t)
    : Input.t :=
    let file_name := Native.String.to_string (Native.Base64.decode file_name) in
    let content := Native.String.to_string (Native.Base64.decode content) in
    Input.file (File.Input.read file_name content).

  Definition import (input : Native.String.t) : Input.t + string :=
    match Native.String.tokenize input with
    | [] => inr "The input cannot be empty."
    | command :: arguments =>
      let command := Command.of_string (Native.String.to_string command) in
      match (command, arguments) with
      | (None, _) => inr "Invalid command."
      | (Some Command.file_read, [file_name; content]) =>
        let file_name := Native.String.to_string (Native.Base64.decode file_name) in
        let content := Native.String.to_string (Native.Base64.decode content) in
        inl (Input.file (File.Input.read file_name content))
      | (Some Command.tcp_client_socket_accepted, [id]) =>
        match Native.String.to_nat id with
        | None => inr "Expected an integer."
        | Some id =>
          let id := TCPClientSocket.Id.new id in
          inl (Input.client_socket (TCPClientSocket.Input.accepted id))
        end
      | (Some Command.tcp_client_socket_read, [id; content]) =>
        match Native.String.to_nat id with
        | None => inr "Expected an integer."
        | Some id =>
          let id := TCPClientSocket.Id.new id in
          let content := Native.String.to_string (Native.Base64.decode content) in
          inl (Input.client_socket (TCPClientSocket.Input.read id content))
        end
      | (Some Command.tcp_server_socket_bound, [id]) =>
        match Native.String.to_nat id with
        | None => inr "Expected an integer."
        | Some id =>
          let id := TCPServerSocket.Id.new id in
          inl (Input.server_socket (TCPServerSocket.Input.bound id))
        end
      | (Some _, _) => inr "Wrong number of arguments."
      end
    end.
End Input.

(** Export output events. *)
Module Output.
  Definition join (s1 s2 : Native.String.t) : Native.String.t :=
    Native.String.append (Native.String.append s1 (Native.String.of_string " ")) s2.

  Definition export (output : Output.t) : Native.String.t :=
    let string s := Native.String.of_string s in
    let base64 s := Native.Base64.encode (Native.String.of_string s) in
    let client_id id :=
      Native.String.of_nat (match id with TCPClientSocket.Id.new id => id end) in
    let server_id id :=
      Native.String.of_nat (match id with TCPServerSocket.Id.new id => id end) in
    match output with
    | Output.log (Log.Output.write message) =>
      join (string "Log.write") (base64 message)
    | Output.file (File.Output.read file_name) =>
      join (string "File.read") (base64 file_name)
    | Output.client_socket (TCPClientSocket.Output.write id message) =>
      join (string "TCPClientSocket.write")
        (join (client_id id) (base64 message))
    | Output.client_socket (TCPClientSocket.Output.close id) =>
      join (string "TCPClientSocket.close") (client_id id)
    | Output.server_socket (TCPServerSocket.Output.bind port) =>
      let port := Native.String.of_nat port in
      join (string "TCPServerSocket.bind") port
    | Output.server_socket (TCPServerSocket.Output.close id) =>
      join (string "TCPServerSocket.close") (server_id id)
    end.
End Output.

Definition run_ocaml (sig : Signature.t) (mem : Memory.t sig)
  (start : unit -> C sig unit) (handle : Input.t -> C sig unit) : unit :=
  let last triple :=
    match triple with
    | (x, y, z) => (y, z)
    end in
  let system := Native.Process.run (Native.String.of_string "./systemProxy.native") in
  let fix print_outputs outputs :=
    match outputs with
    | [] => tt
    | output :: outputs =>
      let _ := Native.Process.print_line (Output.export output) system in
      print_outputs outputs
    end in
  let (mem, outputs) := last (C.run mem (start tt)) in
  let _ := print_outputs outputs in
  let _ := Native.Process.fold_lines _ system mem (fun mem input =>
    match Input.import input with
    | inl input =>
      let (mem, outputs) := last (C.run mem (handle input)) in
      mem
    | inr error_message =>
      let error_message := "Input ignored: " ++ error_message in
      let _ := Native.print_error (Native.String.of_string error_message) in
      mem
    end) in
  tt.