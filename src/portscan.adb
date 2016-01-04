--  This file is covered by the Internet Software Consortium (ISC) License
--  Reference: ../License.txt

with Ada.Strings.Hash;
with GNAT.Regpat;
with Util.Streams.Pipes;
with Util.Streams.Buffered;
with GNAT.String_Split;
with Ada.Exceptions;

package body PortScan is

   package EX  renames Ada.Exceptions;
   package RGX renames GNAT.Regpat;
   package STR renames Util.Streams;
   package GSS renames GNAT.String_Split;


   ------------------------------
   --  scan_entire_ports_tree  --
   ------------------------------
   function scan_entire_ports_tree (portsdir : String) return Boolean
   is
      good_scan  : Boolean;
   begin
      --  tree must be already mounted in the scan slave.
      --  However, prescan works on the real ports tree, not the mount.
      prescan_ports_tree (portsdir);
      parallel_deep_scan (success => good_scan);

      return good_scan;
   end scan_entire_ports_tree;


   ------------------------
   --  scan_single_port  --
   ------------------------
   function scan_single_port (repository, catport : String)
                              return Boolean
   is
      xports : constant String := JT.USS (PM.configuration.dir_buildbase) &
                                  ss_base & "/xports";

      procedure dig (cursor : block_crate.Cursor);
      target    : port_index;
      aborted   : Boolean := False;
      uscatport : JT.Text := JT.SUS (catport);

      procedure dig (cursor : block_crate.Cursor)
      is
         new_target : port_index := block_crate.Element (cursor);
      begin
         if not aborted then
            if not all_ports (new_target).scanned then
               populate_port_data (new_target);
               all_ports (new_target).blocked_by.Iterate (dig'Access);
            end if;
         end if;
      exception
         when issue : nonexistent_port =>
            aborted := True;
            TIO.Put_Line (LAT.LF & "Scan aborted because dependency could " &
                            "not be located.");
            TIO.Put_Line (EX.Exception_Message (issue));
         when issue : bmake_execution =>
            aborted := True;
            TIO.Put_Line (LAT.LF & "Scan aborted because 'make' encounted " &
                            "an error in the Makefile.");
            TIO.Put_Line (EX.Exception_Message (issue));
         when issue : make_garbage =>
            aborted := True;
            TIO.Put_Line (LAT.LF & "Scan aborted because dependency is " &
                            "malformed.");
            TIO.Put_Line (EX.Exception_Message (issue));
         when issue : others =>
            aborted := True;
            TIO.Put_Line (LAT.LF & "Scan aborted for an unknown reason.");
            TIO.Put_Line (EX.Exception_Message (issue));
      end dig;
   begin
      if not AD.Exists (xports & "/" & catport & "/Makefile") then
         return False;
      end if;
      if not prescanned then
         prescan_ports_tree (xports);
      end if;
      if ports_keys.Contains (Key => uscatport) then
         target := ports_keys.Element (Key => uscatport);
      else
         return False;
      end if;
      populate_port_data (target);
      all_ports (target).blocked_by.Iterate (dig'Access);
      return not aborted;

   end scan_single_port;


   --------------------------
   --  set_build_priority  --
   --------------------------
   procedure set_build_priority is
   begin
      iterate_reverse_deps;
      iterate_drill_down;
   end set_build_priority;


   ------------------------
   --  reset_ports_tree  --
   ------------------------
   procedure reset_ports_tree
   is
      PR : port_record_access;
   begin
      for k in dim_all_ports'Range loop
         PR  := all_ports (k)'Access;

         PR.sequence_id   := 0;
         PR.key_cursor    := portkey_crate.No_Element;
         PR.jobs          := 1;
         PR.ignore_reason := JT.blank;
         PR.port_version  := JT.blank;
         PR.package_name  := JT.blank;
         PR.pkg_dep_query := JT.blank;
         PR.ignored       := False;
         PR.scanned       := False;
         PR.rev_scanned   := False;
         PR.unlist_failed := False;
         PR.work_locked   := False;
         PR.pkg_present   := False;
         PR.deletion_due  := False;
         PR.reverse_score := 0;
         PR.librun.Clear;
         PR.blocks.Clear;
         PR.blocked_by.Clear;
         PR.all_reverse.Clear;
         PR.options.Clear;
      end loop;
      ports_keys.Clear;
      rank_queue.Clear;
      lot_number  := 1;
      lot_counter := 0;
      last_port   := 0;
      prescanned  := False;
      wipe_make_queue;
   end reset_ports_tree;


   --  PRIVATE FUNCTIONS  --


   --------------------------
   --  iterate_drill_down  --
   --------------------------
   procedure iterate_drill_down is
   begin

      rank_queue.Clear;
      for port in port_index'First .. last_port loop
         if all_ports (port).scanned then
            drill_down (next_target => port, original_target => port);
            declare
               ndx : constant port_index :=
                 port_index (all_ports (port).reverse_score);
               QR  : constant queue_record :=
                 (ap_index      => port,
                  reverse_score => ndx);
            begin
               rank_queue.Insert (New_Item => QR);
            end;
         end if;
      end loop;

   end iterate_drill_down;


   --------------------------
   --  parallel_deep_scan  --
   --------------------------
   procedure parallel_deep_scan (success : out Boolean)
   is
      finished : array (scanners) of Boolean := (others => False);
      combined_wait : Boolean := True;
      aborted : Boolean := False;

      task type scan (lot : scanners);
      task body scan
      is
         procedure populate (cursor : subqueue.Cursor);
         procedure populate (cursor : subqueue.Cursor)
         is
            target_port : port_index := subqueue.Element (cursor);
         begin
            if not aborted then
               populate_port_data (target_port);
               mq_progress (lot) := mq_progress (lot) + 1;
            end if;
         exception
            when issue : others =>
               TIO.Put_Line (LAT.LF & "culprit: " &
                               get_catport (all_ports (target_port)));
               EX.Reraise_Occurrence (issue);
         end populate;
      begin
         make_queue (lot).Iterate (populate'Access);
         finished (lot) := True;
      exception
         when issue : nonexistent_port =>
            aborted := True;
            TIO.Put_Line ("Scan aborted because dependency could " &
                            "not be located.");
            TIO.Put_Line (EX.Exception_Message (issue));
         when issue : bmake_execution =>
            aborted := True;
            TIO.Put_Line ("Scan aborted because 'make' encounted " &
                            "an error in the Makefile.");
            TIO.Put_Line (EX.Exception_Message (issue));
         when issue : make_garbage =>
            aborted := True;
            TIO.Put_Line ("Scan aborted because dependency is malformed.");
            TIO.Put_Line (EX.Exception_Message (issue));
         when issue : others =>
            aborted := True;
            TIO.Put_Line ("Scan aborted for an unknown reason.");
            TIO.Put_Line (EX.Exception_Message (issue));
      end scan;

      scan_01 : scan (lot => 1);
      scan_02 : scan (lot => 2);
      scan_03 : scan (lot => 3);
      scan_04 : scan (lot => 4);
      scan_05 : scan (lot => 5);
      scan_06 : scan (lot => 6);
      scan_07 : scan (lot => 7);
      scan_08 : scan (lot => 8);
      scan_09 : scan (lot => 9);
      scan_10 : scan (lot => 10);
      scan_11 : scan (lot => 11);
      scan_12 : scan (lot => 12);
      scan_13 : scan (lot => 13);
      scan_14 : scan (lot => 14);
      scan_15 : scan (lot => 15);
      scan_16 : scan (lot => 16);
      scan_17 : scan (lot => 17);
      scan_18 : scan (lot => 18);
      scan_19 : scan (lot => 19);
      scan_20 : scan (lot => 20);
      scan_21 : scan (lot => 21);
      scan_22 : scan (lot => 22);
      scan_23 : scan (lot => 23);
      scan_24 : scan (lot => 24);
      scan_25 : scan (lot => 25);
      scan_26 : scan (lot => 26);
      scan_27 : scan (lot => 27);
      scan_28 : scan (lot => 28);
      scan_29 : scan (lot => 29);
      scan_30 : scan (lot => 30);
      scan_31 : scan (lot => 31);
      scan_32 : scan (lot => 32);

   begin
      TIO.Put_Line ("Scanning entire ports tree.");
      while combined_wait loop
         delay 5.0;
         TIO.Put (scan_progress);
         combined_wait := False;
         for j in scanners'Range loop
            if not aborted and then not finished (j) then
               combined_wait := True;
               exit;
            end if;
         end loop;
      end loop;
      success := not aborted;
   end parallel_deep_scan;


   -----------------------
   --  wipe_make_queue  --
   -----------------------
   procedure wipe_make_queue is
   begin
      for j in scanners'Range loop
         make_queue (j).Clear;
      end loop;
   end wipe_make_queue;


   ------------------
   --  drill_down  --
   ------------------
   procedure drill_down (next_target     : port_index;
                         original_target : port_index)
   is
      PR : port_record_access := all_ports (next_target)'Access;

      procedure stamp_and_drill (cursor : block_crate.Cursor);
      procedure slurp_scanned (cursor : block_crate.Cursor);

      procedure slurp_scanned (cursor : block_crate.Cursor)
      is
         rev_id  : port_index := block_crate.Element (Position => cursor);
      begin
         if not all_ports (original_target).all_reverse.Contains (rev_id) then
            all_ports (original_target).all_reverse.Insert
              (Key      => rev_id,
               New_Item => rev_id);
         end if;
      end slurp_scanned;

      procedure stamp_and_drill (cursor : block_crate.Cursor)
      is
         pmc : port_index := block_crate.Element (Position => cursor);
      begin
         if not all_ports (original_target).all_reverse.Contains (pmc) then
            all_ports (original_target).all_reverse.Insert
              (Key      => pmc,
               New_Item => pmc);
         end if;
         if pmc = original_target then
            declare
               top_port : constant String :=
                 get_catport (all_ports (original_target));
               this_port : constant String :=
                 get_catport (all_ports (next_target));
            begin
               raise circular_logic with top_port & " <=> " & this_port;
            end;
         end if;

         if not all_ports (pmc).rev_scanned then
            drill_down (next_target => pmc, original_target => pmc);
         end if;
         all_ports (pmc).all_reverse.Iterate (slurp_scanned'Access);
      end stamp_and_drill;

   begin
      if not PR.scanned then
         return;
      end if;
      if PR.rev_scanned then
         --  It is possible to get here if an earlier port scanned this port
         --  as a reverse dependencies
         return;
      end if;
      PR.blocks.Iterate (stamp_and_drill'Access);
      PR.reverse_score := port_index (PR.all_reverse.Length);
      PR.rev_scanned := True;
   end drill_down;


   ----------------------------
   --  iterate_reverse_deps  --
   -----------------------------
   procedure iterate_reverse_deps
   is
      madre : port_index;
      procedure set_reverse (cursor : block_crate.Cursor);
      procedure set_reverse (cursor : block_crate.Cursor) is
      begin
         --  Using conditional insert here causes a finalization error when
         --  the program exists.  Reluctantly, do the condition check manually
         if not all_ports (block_crate.Element (cursor)).blocks.Contains
           (Key => madre)
         then
            all_ports (block_crate.Element (cursor)).blocks.Insert
              (Key => madre, New_Item => madre);
         end if;
      end set_reverse;
   begin
      for port in port_index'First .. last_port loop
         if all_ports (port).scanned then
            madre := port;
            all_ports (port).blocked_by.Iterate (set_reverse'Access);
         end if;
      end loop;
   end iterate_reverse_deps;


   --------------------------
   --  populate_port_data  --
   --------------------------
   procedure populate_port_data (target : port_index)
   is
      xports   : constant String := "/xports";
      catport  : String := get_catport (all_ports (target));
      fullport : constant String := xports & "/" & catport;
      chroot   : constant String := "/usr/sbin/chroot " &
                 JT.USS (PM.configuration.dir_buildbase) & ss_base;
      command  : constant String := chroot & " /usr/bin/make -C " & fullport &
                 " PORTSDIR=" & xports & " PACKAGE_BUILDING=yes" & get_ccache &
                 " -VPKGVERSION -VPKGFILE:T -VMAKE_JOBS_NUMBER -VIGNORE" &
                 " -VFETCH_DEPENDS -VEXTRACT_DEPENDS -VPATCH_DEPENDS" &
                 " -VBUILD_DEPENDS -VLIB_DEPENDS -VRUN_DEPENDS" &
                 " -VSELECTED_OPTIONS -VDESELECTED_OPTIONS";
      pipe     : aliased STR.Pipes.Pipe_Stream;
      buffer   : STR.Buffered.Buffered_Stream;
      content  : JT.Text;
      topline  : JT.Text;
      status   : Integer;

      type result_range is range 1 .. 12;

      --  prototypes
      procedure set_depends (line  : JT.Text; dtype : dependency_type);
      procedure set_options (line  : JT.Text; on : Boolean);

      procedure set_depends (line  : JT.Text; dtype : dependency_type)
      is
         subs       : GSS.Slice_Set;
         deps_found : GSS.Slice_Number;
         trimline   : constant JT.Text := JT.trim (line);
         zero_deps  : constant GSS.Slice_Number := GSS.Slice_Number (0);
         dirlen     : constant Natural := xports'Length;

         use type GSS.Slice_Number;
      begin
         if JT.IsBlank (trimline) then
            return;
         end if;

         GSS.Create (S          => subs,
                     From       => JT.USS (trimline),
                     Separators => " " & LAT.HT,
                     Mode       => GSS.Multiple);
         deps_found :=  GSS.Slice_Count (S => subs);
         if deps_found = zero_deps then
            return;
         end if;
         for j in 1 .. deps_found loop
            declare
               workdep : constant String  := GSS.Slice (subs, j);
               fulldep : constant String (1 .. workdep'Length) := workdep;
               colon   : constant Natural := find_colon (fulldep);
               colon1  : constant Natural := colon + 1;
               deprec  : portkey_crate.Cursor;

               use type portkey_crate.Cursor;
            begin
               if colon < 2 then
                  raise make_garbage
                    with dtype'Img & ": " & JT.USS (trimline) &
                    " (" & catport & ")";
               end if;
               if fulldep'Length > colon1 + dirlen + 5 and then
                 fulldep (colon1 .. colon1 + dirlen) = xports & "/"
               then
                  deprec := ports_keys.Find (Key => scrub_phase
                       (fulldep (colon + dirlen + 2 .. fulldep'Last)));
               else
                  deprec := ports_keys.Find (Key => scrub_phase
                       (fulldep (colon1 .. fulldep'Last)));
               end if;

               if deprec = portkey_crate.No_Element then
                  raise nonexistent_port
                    with fulldep (colon1 .. fulldep'Last) &
                    " (" & catport & ")";
               end if;
               declare
                  depindex : port_index := portkey_crate.Element (deprec);
               begin
                  if not all_ports (target).blocked_by.Contains (depindex) then
                     all_ports (target).blocked_by.Insert
                       (Key      => depindex,
                        New_Item => depindex);
                  end if;
                  if dtype in LR_set then
                     if not all_ports (target).librun.Contains (depindex) then
                        all_ports (target).librun.Insert
                          (Key      => depindex,
                           New_Item => depindex);
                     end if;
                  end if;
               end;
            end;
         end loop;
      end set_depends;

      procedure set_options (line  : JT.Text; on : Boolean)
      is
         subs       : GSS.Slice_Set;
         opts_found : GSS.Slice_Number;
         trimline   : constant JT.Text := JT.trim (line);
         zero_opts  : constant GSS.Slice_Number := GSS.Slice_Number (0);

         use type GSS.Slice_Number;
      begin
         if JT.IsBlank (trimline) then
            return;
         end if;
         GSS.Create (S          => subs,
                     From       => JT.USS (trimline),
                     Separators => " ",
                     Mode       => GSS.Multiple);
         opts_found :=  GSS.Slice_Count (S => subs);
         if opts_found = zero_opts then
            return;
         end if;
         for j in 1 .. opts_found loop
            declare
               opt : JT.Text  := JT.SUS (GSS.Slice (subs, j));
            begin
               if not all_ports (target).options.Contains (opt) then
                  all_ports (target).options.Insert (Key => opt,
                                                     New_Item => on);
               end if;
            end;
         end loop;
      end set_options;

   begin
      pipe.Open (Command => command);
      buffer.Initialize (Output => null,
                         Input  => pipe'Unchecked_Access,
                         Size   => 4096);
      buffer.Read (Into => content);
      pipe.Close;

      status := pipe.Get_Exit_Status;
      if status /= 0 then
         raise bmake_execution with catport &
           " (return code =" & status'Img & ")";
      end if;

      for k in result_range loop
         JT.nextline (lineblock => content, firstline => topline);
         case k is
            when 1 => all_ports (target).port_version := topline;
            when 2 => all_ports (target).package_name := topline;
            when 3 => all_ports (target).jobs :=
                 builders (Integer'Value (JT.USS (topline)));
            when 4 =>
               all_ports (target).ignore_reason := topline;
               all_ports (target).ignored := not JT.IsBlank (topline);
            when 5 => set_depends (topline, fetch);
            when 6 => set_depends (topline, extract);
            when 7 => set_depends (topline, patch);
            when 8 => set_depends (topline, build);
            when 9 => set_depends (topline, library);
            when 10 => set_depends (topline, runtime);
            when 11 => set_options (topline, True);
            when 12 => set_options (topline, False);
         end case;
      end loop;
      all_ports (target).scanned := True;
   exception
      when issue : others =>
         EX.Reraise_Occurrence (issue);

   end populate_port_data;


   -----------------
   --  set_cores  --
   -----------------
   procedure set_cores
   is
      command  : constant String := "/sbin/sysctl hw.ncpu";
      pipe     : aliased STR.Pipes.Pipe_Stream;
      buffer   : STR.Buffered.Buffered_Stream;
      content  : JT.Text;
   begin
      --  expected output: "hw.ncpu: C" where C is integer
      pipe.Open (Command => command);
      buffer.Initialize (Output => null,
                         Input  => pipe'Unchecked_Access,
                         Size   => 128);
      buffer.Read (Into => content);
      pipe.Close;
      declare
         str_content : String := JT.USS (content);
         ncpu        : String := str_content (10 .. str_content'Last - 1);
         number      : Positive := Integer'Value (ncpu);
      begin
         if number > Positive (cpu_range'Last) then
            number_cores := cpu_range'Last;
         else
            number_cores := cpu_range (number);
         end if;
      end;
   end set_cores;


   -----------------------
   --  cores_available  --
   -----------------------
   function cores_available return cpu_range is
   begin
      return number_cores;
   end cores_available;


   --------------------------
   --  prescan_ports_tree  --
   --------------------------
   procedure prescan_ports_tree (portsdir : String)
   is
      procedure quick_scan (cursor : string_crate.Cursor);
      Search     : AD.Search_Type;
      Dir_Ent    : AD.Directory_Entry_Type;
      categories : string_crate.Vector;

      --  scan entire ports tree, and for each port hooked into the build,
      --  push an initial port_rec into the all_ports container
      procedure quick_scan (cursor : string_crate.Cursor)
      is
         category : constant String :=
           JT.USS (string_crate.Element (Position => cursor));
      begin
         if AD.Exists (portsdir & "/" & category & "/Makefile") then
            grep_Makefile (portsdir => portsdir, category => category);
         else
            walk_all_subdirectories (portsdir => portsdir,
                                     category => category);
         end if;
      end quick_scan;
   begin
      AD.Start_Search (Search    => Search,
                       Directory => portsdir,
                       Filter    => (AD.Directory => True, others => False),
                       Pattern   => "[a-z]*");

      while AD.More_Entries (Search => Search) loop
         AD.Get_Next_Entry (Search => Search, Directory_Entry => Dir_Ent);
         declare
            category : constant String := AD.Simple_Name (Dir_Ent);
         begin
            categories.Append (New_Item => JT.SUS (category));
         end;
      end loop;
      AD.End_Search (Search => Search);
      categories.Iterate (Process => quick_scan'Access);
      prescanned := True;
   end prescan_ports_tree;


   ------------------
   --  find_colon  --
   ------------------
   function find_colon (Source : String) return Natural
   is
      result : Natural := 0;
      strlen : constant Natural := Source'Length;
   begin
      for j in 1 .. strlen loop
         if Source (j) = LAT.Colon then
            result := j;
            exit;
         end if;
      end loop;
      return result;
   end find_colon;


   -------------------
   --  scrub_phase  --
   -------------------
   function scrub_phase (Source : String) return JT.Text
   is
      reset : constant String (1 .. Source'Length) := Source;
      colon : constant Natural := find_colon (reset);
   begin
      if colon = 0 then
         return JT.SUS (reset);
      end if;
      return JT.SUS (reset (1 .. colon - 1));
   end scrub_phase;


   --------------------------
   --  determine_max_lots  --
   --------------------------
   function get_max_lots return scanners
   is
      first_try : constant Positive := Positive (number_cores) * 3;
   begin
      if first_try > Positive (scanners'Last) then
         return scanners'Last;
      else
         return scanners (first_try);
      end if;
   end get_max_lots;


   ---------------------
   --  grep_Makefile  --
   ---------------------
   procedure grep_Makefile (portsdir, category : String)
   is
      archive  : TIO.File_Type;
      matches  : RGX.Match_Array (0 .. 1);
      pattern  : constant String := "SUBDIR[[:space:]]*[:+:]=[[:space:]]*(.*)";
      regex    : constant RGX.Pattern_Matcher := RGX.Compile (pattern);
      max_lots : constant scanners := get_max_lots;
   begin
      TIO.Open (File => archive,
                Mode => TIO.In_File,
                Name => portsdir & "/" & category & "/Makefile");
      while not TIO.End_Of_File (File => archive) loop
         declare
            line      : constant String := TIO.Get_Line (File => archive);
            blank_rec : port_record;
            kc        : portkey_crate.Cursor;
            success   : Boolean;
            use type RGX.Match_Location;
         begin
            RGX.Match (Self => regex, Data => line, Matches => matches);
            if matches (0) /= RGX.No_Match then
               declare
                  portkey : constant JT.Text := JT.SUS (category & '/' &
                    line (matches (1).First .. matches (1).Last));
               begin
                  ports_keys.Insert (Key      => portkey,
                                     New_Item => lot_counter,
                                     Position => kc,
                                     Inserted => success);

                  last_port := lot_counter;
                  all_ports (lot_counter).sequence_id := lot_counter;
                  all_ports (lot_counter).key_cursor := kc;
                  make_queue (lot_number).Append (lot_counter);
               end;
            end if;
         end;

         lot_counter := lot_counter + 1;
         if lot_number = max_lots then
            lot_number := 1;
         else
            lot_number := lot_number + 1;
         end if;
      end loop;
      TIO.Close (File => archive);
   end grep_Makefile;


   -------------------------------
   --  walk_all_subdirectories  --
   -------------------------------
   procedure walk_all_subdirectories (portsdir, category : String)
   is
      inner_search : AD.Search_Type;
      inner_dirent : AD.Directory_Entry_Type;
      max_lots     : constant scanners := get_max_lots;
   begin
      AD.Start_Search (Search    => inner_search,
                       Directory => portsdir & "/" & category,
                       Filter    => (AD.Directory => True, others => False),
                       Pattern   => "");
      while AD.More_Entries (Search => inner_search) loop
         AD.Get_Next_Entry (Search => inner_search,
                            Directory_Entry => inner_dirent);
         declare
            portname  : constant String := AD.Simple_Name (inner_dirent);
            portkey   : constant JT.Text := JT.SUS (category & "/" & portname);
            kc        : portkey_crate.Cursor;
            success   : Boolean;
         begin
            if portname /= "." and then portname /= ".." then
                ports_keys.Insert (Key      => portkey,
                                   New_Item => lot_counter,
                                   Position => kc,
                                   Inserted => success);

               last_port := lot_counter;
               all_ports (lot_counter).sequence_id := lot_counter;
               all_ports (lot_counter).key_cursor := kc;
               make_queue (lot_number).Append (lot_counter);
               lot_counter := lot_counter + 1;
               if lot_number = max_lots then
                  lot_number := 1;
               else
                  lot_number := lot_number + 1;
               end if;
            end if;
         end;
      end loop;
   end walk_all_subdirectories;


   -----------------
   --  port_hash  --
   -----------------
   function port_hash (key : JT.Text) return AC.Hash_Type is
   begin
      return Ada.Strings.Hash (JT.USS (key));
   end port_hash;


   ------------------
   --  block_hash  --
   ------------------
   function block_hash (key : port_index) return AC.Hash_Type is
       preresult : constant AC.Hash_Type := AC.Hash_Type (key);
      use type AC.Hash_Type;
   begin
      --  Equivalent to mod 128
      return preresult and 2#1111111#;
   end block_hash;


   ------------------
   --  block_ekey  --
   ------------------
   function block_ekey (left, right : port_index) return Boolean is
   begin
      return left = right;
   end block_ekey;


   --------------------------------------
   --  "<" function for ranking_crate  --
   --------------------------------------
   function "<" (L, R : queue_record) return Boolean is
   begin
      if L.reverse_score = R.reverse_score then
         return R.ap_index > L.ap_index;
      end if;
      return L.reverse_score > R.reverse_score;
   end "<";


   -------------------
   --  get_catport  --
   -------------------
   function get_catport (PR : port_record) return String
   is
      catport  : JT.Text := portkey_crate.Key (PR.key_cursor);
   begin
      return JT.USS (catport);
   end get_catport;


   ------------------
   --  get_ccache  --
   ------------------
   function get_ccache return String
   is
   begin
      if AD.Exists (JT.USS (PM.configuration.dir_ccache)) then
         return " WITH_CCACHE_BUILD=yes CCACHE_DIR=/ccache";
      end if;
      return "";
   end get_ccache;


   ---------------------
   --  scan_progress  --
   ---------------------
   function scan_progress return String
   is
      type percent is delta 0.01 digits 5;
      complete : port_index := 0;
      pc : percent;
   begin
      for k in scanners'Range loop
         complete := complete + mq_progress (k);
      end loop;
      pc := percent (100.0 * Float (complete) / Float (last_port));
      return " progress:" & pc'Img & "%              " & LAT.CR;
   end scan_progress;

end PortScan;
