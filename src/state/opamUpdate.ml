(**************************************************************************)
(*                                                                        *)
(*    Copyright 2012-2015 OCamlPro                                        *)
(*    Copyright 2012 INRIA                                                *)
(*                                                                        *)
(*  All rights reserved.This file is distributed under the terms of the   *)
(*  GNU Lesser General Public License version 3.0 with linking            *)
(*  exception.                                                            *)
(*                                                                        *)
(*  OPAM is distributed in the hope that it will be useful, but WITHOUT   *)
(*  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY    *)
(*  or FITNESS FOR A PARTICULAR PURPOSE.See the GNU General Public        *)
(*  License for more details.                                             *)
(*                                                                        *)
(**************************************************************************)

open OpamTypes
open OpamStateTypes
open OpamProcess.Job.Op
open OpamFilename.Op

let log fmt = OpamConsole.log "UPDATE" fmt
let slog = OpamConsole.slog

let fetch_dev_package url srcdir nv =
  let remote_url = OpamFile.URL.url url in
  let mirrors = remote_url :: OpamFile.URL.mirrors url in
  let checksum = OpamFile.URL.checksum url in
  log "updating %a" (slog OpamUrl.to_string) remote_url;
  let text =
    OpamProcess.make_command_text
      (OpamPackage.Name.to_string nv.name)
      (OpamUrl.string_of_backend remote_url.OpamUrl.backend) in
  OpamProcess.Job.with_text text @@
  OpamRepository.pull_url nv srcdir checksum mirrors
  @@| function
  | Not_available _ ->
    (* OpamConsole.error "Upstream %s of %s is unavailable" u *)
    (*   (OpamPackage.to_string nv); *)
    false
  | Up_to_date _    -> false
  | Result _        -> true

let update_state nv pin opam st =
  { st with
    opams = OpamPackage.Map.add nv opam st.opams;
    packages = OpamPackage.Set.add nv st.packages;
    available_packages = lazy (
      if OpamFilter.eval_to_bool ~default:false
          (OpamPackageVar.resolve_switch st) (OpamFile.OPAM.available opam)
      then OpamPackage.Set.add nv (Lazy.force st.available_packages)
      else OpamPackage.Set.remove nv (Lazy.force st.available_packages)
    );
    pinned = OpamPackage.Name.Map.add nv.name (nv.version, pin) st.pinned;
    reinstall = OpamPackage.Set.add nv st.reinstall;
  }

let local_opam ?(check=false) ?copy_invalid_to name dir =
  match OpamPinned.find_opam_file_in_source name dir with
  | None -> None
  | Some local_opam ->
    let warns, opam_opt = OpamFile.OPAM.validate_file local_opam in
    if check && warns <> [] then
      (OpamConsole.warning
         "%s opam file from upstream of %s (fix with 'opam pin edit'):"
         (if opam_opt = None then "Fatal errors, not using"
          else "Failed checks in")
         (OpamConsole.colorise `bold (OpamPackage.Name.to_string name));
       OpamConsole.errmsg "%s\n"
         (OpamFile.OPAM.warns_to_string warns));
    (match opam_opt, copy_invalid_to with
     | None, Some dst ->
       if not check then
         OpamConsole.warning
           "Errors in opam file from %s upstream, ignored (fix with \
            'opam pin edit')"
           (OpamPackage.Name.to_string name);
       OpamFilename.copy ~src:(OpamFile.filename local_opam) ~dst:dst
     | _ -> ());
    OpamStd.Option.map
      (fun opam ->
         let opam = OpamFile.OPAM.with_name opam name in
         if OpamFilename.dirname (OpamFile.filename local_opam) <> dir then
           (* Subdir metadata *)
           OpamFileHandling.add_aux_files opam
         else opam)
      opam_opt

let pinned_package st ?fixed_version name =
  log "update-pinned-package %s" (OpamPackage.Name.to_string name);
  let root = st.switch_global.root in
  let overlay_dir = OpamPath.Switch.Overlay.package root st.switch name in
  let overlay_opam = OpamFileHandling.read_opam overlay_dir in
  match OpamPackage.Name.Map.find name st.pinned with
  | _, Version _ -> Done ((fun st -> st), false)
  | version, (Source url as pin) ->
  let version = OpamStd.Option.default  version fixed_version in
  let nv = OpamPackage.create name version in
  let urlf = OpamFile.URL.create url in
  let srcdir = OpamPath.Switch.dev_package root st.switch name in
  (* Four versions of the metadata: from the old and new versions
     of the package, from the current overlay, and also the original one
     from the repo *)
  let old_source_opam = local_opam name srcdir in
  let repo_opam =
    let packages =
      OpamPackage.Map.filter (fun nv _ -> nv.name = name) st.repos_package_index
    in
    (* get the latest version below v *)
    match OpamPackage.Map.split nv packages with
    | _, (Some opam), _ -> Some opam
    | below, None, _ when not (OpamPackage.Map.is_empty below) ->
      Some (snd (OpamPackage.Map.max_binding below))
    | _, None, above when not (OpamPackage.Map.is_empty above) ->
      Some (snd (OpamPackage.Map.min_binding above))
    | _ -> None
  in
  (* Do the update *)
  fetch_dev_package urlf srcdir nv @@+ fun result ->
  let new_source_opam =
    let copy_invalid_to =
      OpamFile.filename (OpamPath.Switch.Overlay.tmp_opam root st.switch name)
    in
    local_opam ~copy_invalid_to ~check:true name srcdir
  in
  let equal_opam a b =
    let cleanup_opam o =
      let o = OpamFile.OPAM.with_version_opt o None in
      let o = OpamFile.OPAM.with_url_opt o None in
      OpamFile.OPAM.effective_part o
    in
    cleanup_opam a = cleanup_opam b
  in
  let changed_opam old new_ = match old, new_ with
    | None, Some _ -> true
    | _, None -> false
    | Some a, Some b -> not (equal_opam a b)
  in
  let save_overlay opam =
    OpamFilename.mkdir overlay_dir;
    let opam_file = OpamPath.Switch.Overlay.opam root st.switch name in
    List.iter OpamFilename.remove
      OpamPath.Switch.Overlay.[
        OpamFile.filename opam_file;
        OpamFile.filename (url root st.switch name);
        OpamFile.filename (descr root st.switch name);
      ];
    let files_dir = OpamPath.Switch.Overlay.files root st.switch name in
    OpamFilename.rmdir files_dir;
    let opam = OpamFile.OPAM.with_url opam urlf in
    let opam = OpamFile.OPAM.with_name opam name in
    let opam =
      match fixed_version with
      | Some v -> OpamFile.OPAM.with_version opam v
      | None -> opam
    in
    (match OpamFile.OPAM.(metadata_dir opam, extra_files opam) with
     | Some srcdir, Some files ->
       List.iter (fun (file, hash) ->
           let src = OpamFilename.create (srcdir/"files") file in
           if OpamFilename.digest src = hash then
             OpamFilename.copy ~src
               ~dst:(OpamFilename.create files_dir file)
           else
             OpamConsole.warning "Ignoring file %s with invalid hash"
               (OpamFilename.to_string src))
         files
     | _ -> ());
    OpamFile.OPAM.write opam_file
      (OpamFile.OPAM.with_extra_files_opt opam None);
    opam
  in
  match new_source_opam with
  | Some new_opam
    when result &&
         changed_opam old_source_opam new_source_opam &&
         changed_opam overlay_opam new_source_opam ->
    (* Metadata from the package source changed *)
    if not (changed_opam old_source_opam overlay_opam) ||
       not (changed_opam repo_opam overlay_opam)
    then
      (* No manual changes *)
      (OpamConsole.formatted_msg
         "[%s] Installing new package description from upstream %s\n"
         (OpamConsole.colorise `green (OpamPackage.Name.to_string name))
         (OpamUrl.to_string url);
       let opam = save_overlay new_opam in
       Done (update_state nv pin opam, true))
    else if
      OpamConsole.formatted_msg
        "[%s] Conflicting update of the metadata from %s."
        (OpamConsole.colorise `green (OpamPackage.Name.to_string name))
        (OpamUrl.to_string url);
      OpamConsole.confirm "\nOverride files in %s (there will be a backup) ?"
        (OpamFilename.Dir.to_string overlay_dir)
    then (
      let bak =
        OpamPath.backup_dir root / (OpamPackage.Name.to_string name ^ ".bak")
      in
      OpamFilename.mkdir (OpamPath.backup_dir root);
      OpamFilename.rmdir bak;
      OpamFilename.copy_dir ~src:overlay_dir ~dst:bak;
      OpamConsole.formatted_msg "User metadata backed up in %s\n"
        (OpamFilename.Dir.to_string bak);
      let opam = save_overlay new_opam in
      Done (update_state nv pin opam, true))
    else
      Done ((fun st -> st), true)
  | _ when overlay_opam = None ->
    let new_opam = OpamStd.Option.Op.(
        new_source_opam ++
        repo_opam ++
        old_source_opam +!
        OpamSwitchState.opam st nv
      ) in
    let opam = save_overlay new_opam in
    Done (update_state nv pin opam, true)
  | _ ->
    Done ((fun st -> st), result)

let dev_package st nv =
  log "update-dev-package %a" (slog OpamPackage.to_string) nv;
  let name = nv.name in
  match OpamPackage.Name.Map.find_opt name st.pinned with
  | Some (v, Source _) when v = nv.version ->
    pinned_package st name
  | _ ->
    match OpamSwitchState.url st nv with
    | None     -> Done ((fun st -> st), false)
    | Some url ->
      if (OpamFile.URL.url url).OpamUrl.backend = `http then
        Done ((fun st -> st), false)
      else
        fetch_dev_package url
          (OpamPath.dev_package st.switch_global.root nv) nv
        @@| fun result -> (fun st -> st), result

let dev_packages st packages =
  log "update-dev-packages";
  let command nv =
    OpamProcess.Job.ignore_errors
      ~default:((fun st -> st), OpamPackage.Set.empty) @@
    dev_package st nv @@| fun (st_update, changed) ->
    st_update, match changed with
    | true -> OpamPackage.Set.singleton nv
    | false -> OpamPackage.Set.empty
  in
  let merge (st_update1, set1) (st_update2, set2) =
    (fun st -> st_update1 (st_update2 st)),
    OpamPackage.Set.union set1 set2
  in
  let st_update, updated_set =
    OpamParallel.reduce ~jobs:OpamStateConfig.(!r.dl_jobs)
      ~command
      ~merge
      ~nil:((fun st -> st), OpamPackage.Set.empty)
      (OpamPackage.Set.elements packages)
  in
  let st = st_update st in
  let st =
    OpamSwitchAction.add_to_reinstall st ~unpinned_only:false updated_set
  in
  st, updated_set
(* !X 'update' should not touch switch data, but the dev package mirrors
   are still shared, so for the moment other switches will miss the reinstall

  let pinned =
    OpamPackage.Set.filter
      (fun nv -> OpamPackage.Name.Map.mem nv.name st.pinned)
      packages
  in
  let unpinned_updates = updated_set -- pinned in
  OpamGlobalState.fold_switches (fun switch state_file () ->
      if switch <> st.switch then
        OpamSwitchAction.add_to_reinstall st.switch_global switch state_file
          ~unpinned_only:true unpinned_updates)
    st.switch_global ();
*)

let pinned_packages st names =
  log "update-pinned-packages";
  let command name =
    OpamProcess.Job.ignore_errors
      ~default:((fun st -> st), OpamPackage.Name.Set.empty) @@
    pinned_package st name @@| fun (st_update, changed) ->
    st_update,
    match changed with
    | true -> OpamPackage.Name.Set.singleton name
    | false -> OpamPackage.Name.Set.empty
  in
  let merge (st_update1, set1) (st_update2, set2) =
    (fun st -> st_update1 (st_update2 st)),
    OpamPackage.Name.Set.union set1 set2
  in
  let st_update, updates =
    OpamParallel.reduce
      ~jobs:(OpamFile.Config.jobs st.switch_global.config)
      ~command
      ~merge
      ~nil:((fun st -> st), OpamPackage.Name.Set.empty)
      (OpamPackage.Name.Set.elements names)
  in
  let st = st_update st in
  let updates =
    OpamPackage.Name.Set.fold (fun name acc ->
        OpamPackage.Set.add (OpamPinned.package st name) acc)
      updates OpamPackage.Set.empty
  in
  OpamSwitchAction.add_to_reinstall st ~unpinned_only:false updates,
  updates

(* Download a package from its upstream source, using 'cache_dir' as cache
   directory. *)
let download_upstream st nv dirname =
  match OpamSwitchState.url st nv with
  | None   -> Done None
  | Some u ->
    let remote_url = OpamFile.URL.url u in
    let mirrors = remote_url :: OpamFile.URL.mirrors u in
    let checksum = OpamFile.URL.checksum u in
    let text =
      OpamProcess.make_command_text (OpamPackage.name_to_string nv)
        (OpamUrl.string_of_backend remote_url.OpamUrl.backend)
    in
    OpamProcess.Job.with_text text @@
    OpamRepository.pull_url nv dirname checksum mirrors
    @@| OpamStd.Option.some
