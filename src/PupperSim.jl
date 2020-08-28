﻿module PupperSim    #  9.716722 seconds (11.72 M allocations: 650.717 MiB, 1.66% gc time)
                    # 10.893923 seconds (13.63 M allocations: 756.021 MiB, 2.05% gc time)
                    # 13.839607 seconds (16.71 M allocations: 918.154 MiB, 1.52% gc time)

# modified from https://github.com/klowrey/MujocoSim.jl/

export loadmodel, pupper, simulate

@time using GLFW                    # 0.418646 seconds (564.20 k allocations: 33.920 MiB)
@time using MuJoCo                  # 0.705183 seconds (2.45 M allocations: 162.621 MiB)
@time using StaticArrays            # 0.000598 seconds (482 allocations: 29.875 KiB)
@time using FixedPointNumbers       # 0.058240 seconds (121.71 k allocations: 7.553 MiB)
@time using ColorTypes              # 0.352808 seconds (366.70 k allocations: 22.285 MiB)

const use_VideoIO = true            # Sys.iswindows()

@static if use_VideoIO
    @time using VideoIO             # 2.877718 seconds (6.32 M allocations: 345.427 MiB, 5.85% gc time)

    const max_video_duration = 60   # max video duration in seconds
    const video_fps = 30            # frames per second determined by GLFW.GetPrimaryMonitor refresh rate
    const max_video_frames = video_fps * max_video_duration
else
    @time using FFMPEG              # 1.175542 seconds (3.00 M allocations: 160.817 MiB, 3.63% gc time)
end

@time using QuadrupedController     # 1.068143 seconds (3.38 M allocations: 171.183 MiB, 10.19% gc time)

##################################################### globals
const fontscale = mj.FONTSCALE_200  # can be 100, 150, 200
const maxgeom = 5000                # preallocated geom array in mjvScene

const TPixel = RGB{N0f8}            # Pixel type
const vfname = "puppersim.mp4"      # Video file name

mutable struct mjSim
   # visual interaction controls
   lastx::Float64
   lasty::Float64
   button_left::Bool
   button_middle::Bool
   button_right::Bool

   lastbutton::GLFW.MouseButton
   lastclicktm::Float64
   lastcmdkey::Union{GLFW.Key, Nothing}

   refreshrate::Int

   # function keys
   showhelp::Int
   showoption::Bool
   showinfo::Bool
   showdepth::Bool
   showfullscreen::Bool
   # stereo::Bool
   showsensor::Bool
   # profiler::Bool

   slowmotion::Bool
   paused::Bool
   keyreset::Int

   record::Any
   vidbuf::Vector{UInt8}
   imgstack::Array{Array{TPixel,2},1}

   framecount::Float64
   #framenum::Int
   #lastframenum::Int

   # MuJoCo things
   scn::Ref{mjvScene}
   cam::Ref{mjvCamera}
   vopt::Ref{mjvOption}
   pert::Ref{mjvPerturb}
   con::Ref{mjrContext}
   figsensor::Ref{mjvFigure}
   m::jlModel
   d::jlData

   # Robot controller
   robot::Union{Robot, Nothing}

   # GLFW handle
   window::GLFW.Window
   vmode::GLFW.VidMode

   #uistate::mjuiState
   #ui0::mjUI
   #ui1::mjUI

   function mjSim(m::jlModel, d::jlData, name::String; width=0, height=0)
      vmode = GLFW.GetVideoMode(GLFW.GetPrimaryMonitor())
      println("monitor resolution: $(vmode.width)x$(vmode.height)")
      w = width > 0 ? width : Int(floor(vmode.width / 2))
      h = height > 0 ? height : Int(floor(vmode.height / 2))

      new(0.0, 0.0, false, false, false, GLFW.MOUSE_BUTTON_1, 0.0, nothing,
         vmode.refreshrate,
         0, false, false, false, false, false, false, true, 0,
         nothing,
         Vector{UInt8}(undef, w*h*sizeof(TPixel)),
         [],
         0.0, #0, 0,
         Ref(mjvScene()),
         Ref(mjvCamera()),
         Ref(mjvOption()),
         Ref(mjvPerturb()),
         Ref(mjrContext()),
         Ref(mjvFigure()),
         m, d,
         nothing,
         GLFW.CreateWindow(w, h, name),
         vmode
      )
   end
end

#export mjSim

const keycmds = Dict{GLFW.Key, Function}(
   GLFW.KEY_F1=>(s)->begin  # help
      s.showhelp += 1
      if s.showhelp > 2 s.showhelp = 0 end
   end,
   GLFW.KEY_F2=>(s)->begin  # option
      s.showoption = !s.showoption;
   end,
   GLFW.KEY_F3=>(s)->begin  # info
      s.showinfo = !s.showinfo;
   end,
   GLFW.KEY_F4=>(s)->begin  # depth
      s.showdepth = !s.showdepth;
   end,
   GLFW.KEY_F5=>(s)->begin  # toggle full screen
      s.showfullscreen = !s.showfullscreen;
      s.showfullscreen ? GLFW.MaximizeWindow(s.window) : GLFW.RestoreWindow(s.window)
   end,
   #GLFW.KEY_F6=>(s)->begin  # stereo
   #   s.stereo = s.scn.stereo == mj.mjSTEREO_NONE ? mjSTEREO_QUADBUFFERED : mj.mjSTEREO_NONE
   #   s.scn[].stereo
   #end,
   GLFW.KEY_F7=>(s)->begin  # sensor figure
      s.showsensor = !s.showsensor;
   end,
   GLFW.KEY_F8=>(s)->begin  # profiler
      s.showprofiler = !s.showprofiler;
   end,
   GLFW.KEY_ENTER=>(s)->begin  # slow motion
      s.slowmotion = !s.slowmotion;
      s.slowmotion ? println("Slow Motion Mode!") : println("Normal Speed Mode!")
   end,
   GLFW.KEY_SPACE=>(s)->begin  # pause
      s.paused = !s.paused
      s.paused ? println("Paused") : println("Running")
   end,
   GLFW.KEY_PAGE_UP=>(s)->begin    # previous keyreset
      s.keyreset = min(s.m.m[].nkey - 1, s.keyreset + 1)
   end,
   GLFW.KEY_PAGE_DOWN=>(s)->begin  # next keyreset
      s.keyreset = max(-1, s.keyreset - 1)
   end,
   # continue with reset
   GLFW.KEY_BACKSPACE=>(s)->begin  # reset
      mj_resetData(s.m.m, s.d.d)
      if s.keyreset >= 0 && s.keyreset < s.m.m[].nkey
         s.d[].time = s.m.key_time[s.keyreset+1]
         s.d.qpos[:] = s.m.key_qpos[:,s.keyreset+1]
         s.d.qvel[:] = s.m.key_qvel[:,s.keyreset+1]
         s.d.act[:]  = s.m.key_act[:,s.keyreset+1]
      end
      mj_forward(s.m, s.d)
      #profilerupdate()
      sensorupdate(s)
   end,
   GLFW.KEY_RIGHT=>(s)->begin  # step forward
      if s.paused
         mj_step(s.m, s.d)
         #profilerupdate()
         sensorupdate(s)
      end
   end,
   GLFW.KEY_LEFT=>(s)->begin  # step back
   #    if s.paused
   #       dt = s.m.m[].opt.timestep
   #       s.m.m[].opt.timestep = -dt
   #       #cleartimers(s.d);
   #       mj_step(s.m, s.d);
   #       s.m.m[].opt.timestep = dt
   #       #profilerupdate()
   #       sensorupdate(s)
   #    end
   end,
   GLFW.KEY_DOWN=>(s)->begin  # step forward 100
      if s.paused
         #cleartimers(d);
         for n=1:100 mj_step(s.m, s.d) end
         #profilerupdate();
         sensorupdate(s)
      end
   end,
   GLFW.KEY_UP=>(s)->begin  # step back 100
   #    if s.paused
   #       dt = s.m.m[].opt.timestep
   #       s.m.m[].opt.timestep = -dt
   #       #cleartimers(d)
   #       for n=1:100 mj_step(s.m, s.d) end
   #       s.m.m[].opt.timestep = dt
   #       #profilerupdate();
   #       sensorupdate(s)
   #    end
   end,
   GLFW.KEY_ESCAPE=>(s)->begin  # free camera
      s.cam[]._type = Int(mj.CAMERA_FREE)
   end,
   GLFW.KEY_EQUAL=>(s)->begin  # bigger font
      if fontscale < 200
         fontscale += 50
         mjr_makeContext(s.m.m, s.con, fontscale)
      end
   end,
   GLFW.KEY_MINUS=>(s)->begin  # smaller font
      if fontscale > 100
         fontscale -= 50;
         mjr_makeContext(s.m.m, s.con, fontscale);
      end
   end,
   GLFW.KEY_LEFT_BRACKET=>(s)->begin  # '[' previous fixed camera or free
      fixedcamtype = s.cam[]._type
      if s.m.m[].ncam > 0 && fixedcamtype == Int(mj.CAMERA_FIXED)
         fixedcamid = s.cam[].fixedcamid
         if (fixedcamid  > 0)
            s.cam[].fixedcamid = fixedcamid-1
         elseif fixedcamid == 0
            s.cam[]._type = Int(mj.CAMERA_FREE)
            s.cam[].fixedcamid = fixedcamid-1
         end
      end
   end,
   GLFW.KEY_RIGHT_BRACKET=>(s)->begin  # ']' next fixed camera
      if s.m.m[].ncam > 0
         fixedcamtype = s.cam[]._type
         fixedcamid = s.cam[].fixedcamid
            if fixedcamid < s.m.m[].ncam - 1
                s.cam[].fixedcamid = fixedcamid+1
                s.cam[]._type = Int(mj.CAMERA_FIXED)
            end
      end
   end,
   GLFW.KEY_SEMICOLON=>(s)->begin  # cycle over frame rendering modes
      frame = s.vopt.frame
      s.vopt[].frame = max(0, frame - 1)
   end,
   GLFW.KEY_APOSTROPHE=>(s)->begin  # cycle over frame rendering modes
      frame = s.vopt.frame
      s.vopt[].frame = min(Int(mj.NFRAME)-1, frame+1)
   end,
   GLFW.KEY_PERIOD=>(s)->begin  # cycle over label rendering modes
      label = s.vopt.label
      s.vopt[].label = max(0, label-1)
   end,
   GLFW.KEY_SLASH=>(s)->begin  # cycle over label rendering modes
      label = s.vopt.label
      s.vopt[].label = min(Int(mj.NLABEL)-1, label+1)
   end
)

##################################################### functions
function finish_recording(s::mjSim)
    # Primarily see avio.jl reference in render function below. Also of potential interest:
    # https://github.com/JuliaIO/VideoIO.jl/tree/master/examples
    # https://discourse.julialang.org/t/creating-a-video-from-a-stack-of-images/646/7

    @static if use_VideoIO
        println("Saving video to: $vfname")
        props = [:priv_data => ("crf"=>"22","preset"=>"medium")]
        @time encodedvideopath = VideoIO.encodevideo(vfname, s.imgstack, framerate=30, AVCodecContextProperties=props, silent=false)
        s.imgstack = []
    else
        println("Closing $vfname")
        close(s.record)
    end

    println("Done writing video!")
    s.record = nothing
end

function alignscale(s::mjSim)
   s.cam[].lookat = s.m.m[].stat.center
   s.cam[].distance = 1.5*s.m.m[].stat.extent

   # set to free camera
   s.cam[]._type = Cint(mj.CAMERA_FREE)
end

function str2vec(s::String, len::Int)
   str = zeros(UInt8, len)
   str[1:length(s)] = codeunits(s)
   return str
end

# init sensor figure
function sensorinit(s::mjSim)
   # set figure to default
   mjv_defaultFigure(s.figsensor)

   # set flags
   s.figsensor[].flg_extend = Cint(1)
   s.figsensor[].flg_barplot = Cint(1)

   s.figsensor[].title = str2vec("Sensor data", length(s.figsensor[].title))

   # y-tick nubmer format
   s.figsensor[].yformat = str2vec("%.0f", length(s.figsensor[].yformat))

   # grid size
   s.figsensor[].gridsize = [2, 3]

   # minimum range
   s.figsensor[].range = [[0 1],[-1 1]]
end

# update sensor figure
function sensorupdate(s::mjSim)
   #=
   println("sensorupdate")
   maxline = 10

   for i=1:maxline # clear linepnt
      mj.set(s.figsensor, :linepnt, Cint(0), i)
   end

   lineid = 1 # start with line 0
   m = s.m
   d = s.d

   # loop over sensors
   for n=1:m.m[].nsensor
      # go to next line if type is different
      if (n > 1 && m.sensor_type[n] != m.sensor_type[n - 1])
         lineid = min(lineid+1, maxline)
      end

      # get info about this sensor
      cutoff = m.sensor_cutoff[n] > 0 ? m.sensor_cutoff[n] : 1.0
      adr = m.sensor_adr[n]
      dim = m.sensor_dim[n]

      # data pointer in line
      p = mj.get(s.figsensor, :linepnt, lineid)

      # fill in data for this sensor
      for i=0:(dim-1)
         # check size
         if ((p + 2i) >= Int(mj.MAXLINEPNT) / 2) break end

         x1 = 2p + 4i + 1
         x2 = 2p + 4i + 3
         mj.set(s.figsensor, :linedata, adr+i, lineid, x1)
         mj.set(s.figsensor, :linedata, adr+i, lineid, x2)

         y1 = 2p + 4i + 2
         y2 = 2p + 4i + 4
         se = d.sensordata[adr+i+1]/cutoff
         mj.set(s.figsensor, :linedata,  0, lineid, y1)
         mj.set(s.figsensor, :linedata, se, lineid, y2)
      end

      # update linepnt
      mj.set(s.figsensor, :linepnt,
             min(Int(mj.MAXLINEPNT)-1, p+2dim),
             lineid)
   end
   =#
end

# show sensor figure
function sensorshow(s::mjSim, rect::mjrRect)
   # render figure on the right
   viewport = mjrRect(rect.width - rect.width / 4,
                      rect.bottom,
                      rect.width / 4,
                      rect.height / 3)
   mjr_figure(viewport, s.figsensor, s.con)
end

##################################################### callbacks

global capsflag = 0

function keyboard(s::mjSim, window::GLFW.Window,
                    key::GLFW.Key, scancode::Int32, act::GLFW.Action, mods::Int32)

    if act == GLFW.RELEASE
        if scancode == 82 || scancode == 83 # numeric keypad 0 (Ins) / . (Del)
            end_turn(s.robot)
        end
        # do not act on release or repeat for most keys
        return
    end

    if key == GLFW.KEY_CAPS_LOCK
      global capsflag = (capsflag + 1) % 2
    end

    if capsflag == 1
      println("Caps lock is on. Using keyboard for control keys")
       valid_repeat = key in [GLFW.KEY_LEFT, GLFW.KEY_RIGHT, GLFW.KEY_UP, GLFW.KEY_DOWN,
                              GLFW.KEY_COMMA, GLFW.KEY_PERIOD, GLFW.KEY_PAGE_UP, GLFW.KEY_PAGE_DOWN,
                              GLFW.KEY_END, GLFW.KEY_HOME]  # height, pitch, and roll
       # valid_repeat = scancode in [73 81 71 79 75 77 72 80 309 55]  # height, pitch, and roll
       if act == GLFW.REPEAT && !valid_repeat return end

       println("key: $key, scancode: $scancode, act: $act, mods: $mods")

       """
       Velocity
       key: KEY_KP_9, scancode: 73, act: PRESS, mods: 0    # Up
       key: KEY_KP_9, scancode: 73, act: RELEASE, mods: 0
       key: KEY_KP_3, scancode: 81, act: PRESS, mods: 0    # Down
       key: KEY_KP_3, scancode: 81, act: RELEASE, mods: 0

       Height
       key: KEY_KP_7, scancode: 71, act: PRESS, mods: 0    # Up
       key: KEY_KP_7, scancode: 71, act: RELEASE, mods: 0
       key: KEY_KP_1, scancode: 79, act: PRESS, mods: 0    # Down
       key: KEY_KP_1, scancode: 79, act: RELEASE, mods: 0

       Yaw
       key: KEY_KP_4, scancode: 75, act: PRESS, mods: 0    # Left
       key: KEY_KP_4, scancode: 75, act: RELEASE, mods: 0
       key: KEY_KP_6, scancode: 77, act: PRESS, mods: 0    # Right
       key: KEY_KP_6, scancode: 77, act: RELEASE, mods: 0

       Pitch
       key: KEY_KP_8, scancode: 72, act: PRESS, mods: 0    # Down
       key: KEY_KP_8, scancode: 72, act: RELEASE, mods: 0
       key: KEY_KP_2, scancode: 80, act: PRESS, mods: 0    # Up
       key: KEY_KP_2, scancode: 80, act: RELEASE, mods: 0

       Roll
       scancode: 309   # Left
       scancode: 55    # Right
       """

       # Velocity PgUp / PgDn
       # if scancode == 73   # numeric keypad 9 (PgUp)
       if key == GLFW.KEY_PAGE_UP   # PgUp
           s.robot.command.horizontal_velocity[1] += 0.01; return
       elseif key == GLFW.KEY_PAGE_DOWN   # PgDn
       # elseif scancode == 81   # numeric keypad 3 (PgDn)
           s.robot.command.horizontal_velocity[1] -= 0.01; return

       # Height Home / End
       elseif key == GLFW.KEY_HOME  # Home
       # elseif scancode == 71   # numeric keypad 7 (Home)
           s.robot.command.height -= 0.005; return
       elseif key == GLFW.KEY_END  # numeric keypad 7 (Home)
       # elseif scancode == 79   # numeric keypad 1 (End)
           s.robot.command.height += 0.005; return

       # Yaw left / right arrow
       elseif key == GLFW.KEY_LEFT  # left arrow
       # elseif scancode == 75   # numeric keypad 4 (left arrow)
           s.robot.command.yaw_rate += 0.02;
           println("yaw:      $(round(s.robot.command.yaw_rate, digits=2))")
           return
       elseif key == GLFW.KEY_RIGHT  # right arrow
       # elseif scancode == 77   # numeric keypad 6 (right arrow)
           s.robot.command.yaw_rate -= 0.02;
           println("yaw:      $(round(s.robot.command.yaw_rate, digits=2))")
           return

       # Pitch up / down arrow
       elseif key == GLFW.KEY_UP  # up arrow
       # elseif scancode == 72   # numeric keypad 8 (up arrow)
           s.robot.command.pitch += 0.03; return
       elseif key == GLFW.KEY_DOWN  # down arrow
       # elseif scancode == 80   # numeric keypad 2 (down arrow)
           s.robot.command.pitch -= 0.03; return

       # Roll left (/) / right (+)
       elseif key == GLFW.KEY_COMMA && mods == 1
       # elseif scancode == 309  # numeric keypad /
           s.robot.command.roll += 0.02; return
       elseif key == GLFW.KEY_PERIOD && mods == 1
       # elseif scancode == 55   # numeric keypad *
           s.robot.command.roll -= 0.02; return

       # Toggle activate (-) / trot (Enter) / hop ()
       elseif scancode == 74   # numeric keypad -
           toggle_activate(s.robot); return
       elseif scancode == 78   # numeric keypad +
           toggle_trot(s.robot); return
       elseif scancode == 284  # numeric keypad Enter
           toggle_hop(s.robot); return

       # Turn left/right (0/.)
       elseif scancode == 82   # numeric keypad 0
           turn_left(s.robot); return
       elseif scancode == 83   # numeric keypad .
           turn_right(s.robot); return
       end

       """
       Unused:
       key: KEY_NUM_LOCK, scancode: 325
       key: KEY_KP_DECIMAL, scancode: 83
       """
   end

   try
      keycmds[key](s) # call anonymous function in keycmds Dict
   catch
      # control keys
      if mods & GLFW.MOD_CONTROL > 0
         if key == GLFW.KEY_A
            alignscale(s)
            return
         #elseif key == GLFW.KEY_L && lastfile[0]
         #   loadmodel(window, s.)
         #   return
         elseif key == GLFW.KEY_P
            #println(s.d.qpos)
            println("== Robot state ==")
            println("velocity: $(round(s.robot.command.horizontal_velocity[1], digits=2))")
            println("height:   $(round(s.robot.command.height, digits=2))")
            println("yaw:      $(round(s.robot.command.yaw_rate, digits=2))")
            println("pitch:    $(round(s.robot.command.pitch, digits=2))")
            println("roll:     $(round(s.robot.command.roll, digits=2))")
            #println("=================")
            return
         elseif key == GLFW.KEY_Q
            s.record !== nothing && finish_recording(s)
            GLFW.SetWindowShouldClose(window, true)
            return
         elseif key == GLFW.KEY_V
            if s.record === nothing
                println("Recording")
                @static if use_VideoIO
                    s.record = 0
                else
                    println("Saving video to $vfname")
                    w, h = GLFW.GetFramebufferSize(window)

                    # -y overwrite output files
                    # -f force format
                    @ffmpeg_env s.record = open(`ffmpeg -y
                                    -f rawvideo -pixel_format rgb24
                                    -video_size $(w)x$(h) -framerate $(s.refreshrate)
                                    -i pipe:0
                                    -preset fast -threads 0
                                    -vf "vflip" $vfname`, "w")
                end
            else
                finish_recording(s)
            end
            return
         end
      else  # <Ctrl> key not pressed
         #println("NVISFLAG: $(Int(mj.NVISFLAG)), mj.VISSTRING: $(mj.VISSTRING)\nNRNDFLAG: $(Int(mj.NRNDFLAG)), RNDSTRING: $(mj.RNDSTRING), NGROUP: $(mj.NGROUP)")

         """
         # check for robot command key (I, J, K, or L)
         if (key in [GLFW.KEY_I, GLFW.KEY_J, GLFW.KEY_K, GLFW.KEY_L])
            s.lastcmdkey = key
            return
         end
        """

         # toggle visualization flag
         # NVISFLAG: 22, VISSTRING: ["Convex Hull" "0" "H"; "Texture" "1" "X"; "Joint" "0" "J"; "Actuator" "0" "U"; "Camera" "0" "Q"; "Light" "0" "Z"; "Tendon" "0" "V"; "Range Finder" "0" "Y"; "Constraint" "0" "N"; "Inertia" "0" "I"; "SCL Inertia" "0" "S"; "Perturb Force" "0" "B"; "Perturb Object" "1" "O"; "Contact Point" "0" "C"; "Contact Force" "0" "F"; "Contact Split" "0" "P"; "Transparent" "0" "T"; "Auto Connect" "0" "A"; "Center of Mass" "0" "M"; "Select Point" "0" "E"; "Static Body" "0" "D"; "Skin" "0" ";"]
         if key != GLFW.KEY_S
            for i=1:Int(mj.NVISFLAG)
                if Int(key) == Int(mj.VISSTRING[i,3][1])
                flags = MVector(s.vopt[].flags)
                flags[i] = flags[i] == 0 ? 1 : 0
                s.vopt[].flags = flags
                return
                end
            end
         end

         # toggle rendering flag
         # NRNDFLAG: 9,  RNDSTRING: ["Shadow" "1" "S"; "Wireframe" "0" "W"; "Reflection" "1" "R"; "Additive" "0" "L"; "Skybox" "1" "K"; "Fog" "0" "G"; "Haze" "1" "/"; "Segment" "0" ","; "Id Color" "0" "."], NGROUP: 6
         for i=1:Int(mj.NRNDFLAG)
            if Int(key) == Int(mj.RNDSTRING[i,3][1])
               flags = MVector(s.scn[].flags)
               flags[i] = flags[i] == 0 ? 1 : 0
               s.scn[].flags = flags
               return
            end
         end

         # toggle geom/site group
         for i=1:Int(mj.NGROUP)
            if Int(key) == i + Int('0')
               if mods & GLFW.MOD_SHIFT == true
                  sitegroup = MVector(s.vopt[].sitegroup)
                  sitegroup[i] = sitegroup[i] > 0 ? 0 : 1
                  s.vopt[].sitegroup[i] = sitegroup
                  return
               else
                  geomgroup = MVector(s.vopt[].geomgroup)
                  geomgroup[i] = geomgroup[i] > 0 ? 0 : 1
                  s.vopt[].geomgroup = geomgroup
                  return
               end
            end
         end
      end
   end
end

function mouse_move(s::mjSim, window::GLFW.Window,
                    xpos::Float64, ypos::Float64)
   # no buttons down: nothing to do
   if !s.button_left && !s.button_middle && !s.button_right
      return
   end

   # compute mouse displacement, save
   dx = xpos - s.lastx
   dy = ypos - s.lasty
   s.lastx = xpos
   s.lasty = ypos

   width, height = GLFW.GetWindowSize(window)

   mod_shift = GLFW.GetKey(window, GLFW.KEY_LEFT_SHIFT) || GLFW.GetKey(window, GLFW.KEY_RIGHT_SHIFT)

   # determine action based on mouse button
   if s.button_right
      action = mod_shift ? Int(mj.MOUSE_MOVE_H) : Int(mj.MOUSE_MOVE_V)
   elseif s.button_left
      action = mod_shift ? Int(mj.MOUSE_ROTATE_H) : Int(mj.MOUSE_ROTATE_V)
   else
      action = Int(mj.MOUSE_ZOOM)
   end

   # move perturb or camera
   if s.pert[].active != 0
      mjv_movePerturb(s.m.m, s.d.d, action,
                      dx / height, dy / height,
                      s.scn, s.pert);
   else
      mjv_moveCamera(s.m.m, action,
                     dx / height, dy / height,
                     s.scn, s.cam)
   end
end

# past data for double-click detection
function mouse_button(s::mjSim, window::GLFW.Window,
                      button::GLFW.MouseButton, act::GLFW.Action, mods::Int32)
   # update button state
   s.button_left = GLFW.GetMouseButton(window, GLFW.MOUSE_BUTTON_LEFT)
   s.button_middle = GLFW.GetMouseButton(window, GLFW.MOUSE_BUTTON_MIDDLE)
   s.button_right = GLFW.GetMouseButton(window, GLFW.MOUSE_BUTTON_RIGHT)

   # Alt: swap left and right
   if mods == GLFW.MOD_ALT
      tmp = s.button_left
      s.button_left = s.button_right
      s.button_right = tmp

      if button == GLFW.MOUSE_BUTTON_LEFT
         button = GLFW.MOUSE_BUTTON_RIGHT;
      elseif button == GLFW.MOUSE_BUTTON_RIGHT
         button = GLFW.MOUSE_BUTTON_LEFT;
      end
   end

   # update mouse position
   x, y = GLFW.GetCursorPos(window)
   s.lastx = x
   s.lasty = y

   # set perturbation
   newperturb = 0;
   if act == GLFW.PRESS && mods == GLFW.MOD_CONTROL && s.pert[].select > 0
      # right: translate;  left: rotate
      if s.button_right
         newperturb = Int(mj.PERT_TRANSLATE)
      elseif s.button_left
         newperturb = Int(mj.PERT_ROTATE)
      end
      # perturbation onset: reset reference
      if newperturb>0 && s.pert[].active==0
         mjv_initPerturb(s.m.m, s.d.d, s.scn, s.pert)
      end
   end
   s.pert[].active = newperturb

   # detect double-click (250 msec)
   if act == GLFW.PRESS && (time() - s.lastclicktm < 0.25) && (button == s.lastbutton)
      # determine selection mode
      if button == GLFW.MOUSE_BUTTON_LEFT
         selmode = 1;
      elseif mods == GLFW.MOD_CONTROL
         selmode = 3; # CTRL + Right Click
      else
         selmode = 2; # Right Click
      end
      # get current window size
      width, height = GLFW.GetWindowSize(window)

      # find geom and 3D click point, get corresponding body
      selpnt = zeros(3)
      selgeom, selskin = Int32(0), Int32(0)
      selbody = mjv_select(s.m.m, s.d.d, s.vopt,
                           width / height, x / width,
                           (height - y) / height,
                           s.scn, selpnt, selgeom, selskin)

      # set lookat point, start tracking is requested
      if selmode == 2 || selmode == 3
         # copy selpnt if geom clicked
         if selbody >= 0
            s.cam[].lookat = SVector{3,Float64}(selpnt...)
         end

         # switch to tracking camera
         if selmode == 3 && selbody >= 0
            s.cam[]._type = Int(mj.CAMERA_TRACKING)
            s.cam[].trackbodyid = selbody
            s.cam[].fixedcamid = -1
         end
      else # set body selection
         if selbody >= 0
            # compute localpos
            tmp = selpnt - s.d.xpos[:,selbody+1]
            res = reshape(s.d.xmat[:,selbody+1], 3, 3)' * tmp
            s.pert[].localpos = SVector{3}(res)

            # record selection
            s.pert[].select = selbody
            s.pert[].skinselect = selskin
         else
            s.pert[].select = 0
            s.pert[].skinselect = -1
         end
      end

      # stop perturbation on select
      s.pert[].active = 0
   end
   # save info
   if act == GLFW.PRESS
      s.lastbutton = button
      s.lastclicktm = time()
   end
end

function scroll(s::mjSim, window::GLFW.Window,
                xoffset::Float64, yoffset::Float64)
   # scroll: emulate vertical mouse motion = 5% of window height
   mjv_moveCamera(s.m.m, Int(mj.MOUSE_ZOOM),
                  0.0, -0.05 * yoffset, s.scn, s.cam);

end

function drop(window::GLFW.Window,
              count::Int, paths::String)
end

# Set up simulator and GLFW window environments
function start(mm::jlModel, dd::jlData, width=1200, height=900) # TODO named args for callbacks
   GLFW.WindowHint(GLFW.SAMPLES, 4)
   GLFW.WindowHint(GLFW.VISIBLE, 1)

   s = mjSim(mm, dd, "Simulate"; width=width, height=height)

   @info("Refresh Rate: $(s.refreshrate)")
   @info("Resolution: $(width)x$(height)")

   # Make the window's context current
   GLFW.MakeContextCurrent(s.window)
   GLFW.SwapInterval(1)

   # init abstract visualization
   mjv_defaultCamera(s.cam)
   mjv_defaultOption(s.vopt)
   #profilerinit();
   sensorinit(s)

   # make empty scene
   mjv_defaultScene(s.scn)
   mjv_makeScene(s.m, s.scn, maxgeom)

   # mujoco setup
   mjv_defaultPerturb(s.pert)
   mjr_defaultContext(s.con)
   mjr_makeContext(s.m, s.con, Int(fontscale)) # model specific setup

   alignscale(s)
   mjv_updateScene(s.m, s.d,
                   s.vopt, s.pert, s.cam, Int(mj.CAT_ALL), s.scn)

   # Set up GLFW callbacks
   GLFW.SetKeyCallback(s.window, (w,k,sc,a,m)->keyboard(s,w,k,sc,a,m))

   GLFW.SetCursorPosCallback(s.window, (w,x,y)->mouse_move(s,w,x,y))
   GLFW.SetMouseButtonCallback(s.window, (w,b,a,m)->mouse_button(s,w,b,a,m))
   GLFW.SetScrollCallback(s.window, (w,x,y)->scroll(s,w,x,y))
   ##GLFW.SetDropCallback(s.window, drop)

   return s
end

# Flip image pixels vertically
@static if use_VideoIO
function vflip(A)
    nrows, ncols = size(A)
    nrp1 = nrows + 1
    for col = 1:ncols
        for row = 1:div(nrows,  2)
            t = A[nrp1-row, col]
            A[nrp1-row, col] = A[row, col]
            A[row, col] = t
        end
    end
end
end

#### To customize what is rendered, change the following functions

function render(s::PupperSim.mjSim, w::GLFW.Window)
    # Update scene
    mjv_updateScene(s.m, s.d, s.vopt, s.pert, s.cam, Int(mj.CAT_ALL), s.scn)

    # Render
    width, height = GLFW.GetFramebufferSize(w)
    mjr_render(mjrRect(0,0,width,height), s.scn, s.con)

    if s.record !== nothing
        @static if use_VideoIO
        if s.record <= max_video_frames
            #@time begin
            s.record += 1

            # Image dims must be a multiple of two
            width  = div(width,  2) * 2 # ensure that width is even
            height = div(height, 2) * 2 # ensure that height is even
            buflen = width * height * sizeof(TPixel)

            # If user has resized the window, we may need to allocate a new buffer
            if length(s.vidbuf) != buflen
                s.vidbuf = Vector{UInt8}(undef, buflen)
            end

            # Get the pixels from MuJoCo
            viewrect = mjrRect(0, 0, width, height)
            mjr_readPixels(s.vidbuf, C_NULL, viewrect, s.con);

            # Reference: @testset "Encoding video across all supported colortypes" block in file avio.jl:
            # (https://github.com/JuliaIO/VideoIO.jl/blob/master/test/avio.jl)

            # Reinterpret the video buffer as pixels
            pixels = reinterpret(TPixel, s.vidbuf)

            # Shape the buffer into an image array
            image = reshape(pixels, width, height)

            # Allocate an uninitialized frame on the image stack
            push!(s.imgstack, Array{TPixel,2}(undef, height, width))

            # Permute image array from column major to row major and write the
            # result to the uninitialized memory at the top of the image stack
            permutedims!(s.imgstack[end], image, (2,1))

            # Flip the image in place on the image stack in the vertical direction
            vflip(s.imgstack[end])
            #end # @time begin
        else    # s.record <= max_video_frames
            finish_recording(s)
        end     # s.record <= max_video_frames
        else    # @static if use_VideoIO
            #@time begin    # This method takes about 15 ms on average per video frame
            buflen = width * height * sizeof(TPixel)

            # If user has resized the window, we may need to allocate a new buffer
            if length(s.vidbuf) != buflen
                s.vidbuf = Vector{UInt8}(undef, buflen)
            end

            # Get the pixels from MuJoCo
            viewrect = mjrRect(0, 0, width, height)
            mjr_readPixels(s.vidbuf, C_NULL, viewrect, s.con);
            write(s.record, s.vidbuf);
            #end # @time begin
        end     # @static if use_VideoIO
    end # s.record !== nothing

    # Swap front and back buffers
    GLFW.SwapBuffers(w)
end

# Load the model (contains robot and its environment)
# width and height control the visual resolution of the simulation
# At resolution (1920, 1080): 5.93 MB/frame, total raw video size: 10.4 GB
# At resolution (1600,  900): 4.12 MB/frame, total raw video size:  7.2 GB
# At resolution (1200,  900): 3.09 MB/frame, total raw video size:  5.4 GB
# At resolution (1024,  768): 2.25 MB/frame, total raw video size:  4.0 GB
# At resolution ( 800,  600): 1.37 MB/frame, total raw video size:  2.4 GB
# At resolution ( 512,  384): 0.56 MB/frame, total raw video size:  1.0 GB
# At resolution ( 400,  300): 0.34 MB/frame, total raw video size:  0.6 GB

"""
    loadmodel(modelfile = "model/Pupper.xml", width = 1920, height = 1080)

Loads MuJoCo XML model and starts the simulation
"""
function loadmodel(
      modelfile = joinpath(dirname(pathof(@__MODULE__)), "../model/Pupper.xml"),
      width = 1920, height = 1080
   )
   ptr_m = mj_loadXML(modelfile, C_NULL)
   ptr_d = mj_makeData(ptr_m)
   m, d = mj.mapmujoco(ptr_m, ptr_d)
   mj_forward(m, d)
   s = PupperSim.start(m, d, width, height)
   @info("Model file: $modelfile")

   # Turn off shadows initially on Linux
   flags = MVector(s.scn[].flags)
   flags[1] = !Sys.islinux()
   s.scn[].flags = flags

   GLFW.SetWindowRefreshCallback(s.window, (w)->render(s,w))

   return s
end

const crouch_height = -0.06
const normal_height = -0.16

function step_script(s::mjSim, robot)
   elapsed_time = round(Int, s.d.d[].time * 1000)  # elapsed time in milliseconds (non-paused simulation)

   # check every 100 milliseconds for another action to take
   if !s.paused && elapsed_time % 100 == 0 && elapsed_time > 0
      #println(elapsed_time, ": ", elapsed_time, "\tframecount: ", round(Int, s.framecount))

      if elapsed_time == 100
         toggle_activate(robot)
      end

      # After he's done falling and getting up, we return to a normal height and pitch
      if elapsed_time == 2000 && robot.command.height > -0.1
         robot.command.height = normal_height
         robot.command.pitch = 0.0
         # We begin trotting here for a few seconds
         toggle_trot(robot)
         println("Standing up and beginning march with velocity", robot.command.horizontal_velocity)
      end

      """
      if s.lastcmdkey == GLFW.KEY_J
         println("User wants to turn left")
         turn_left(robot)
      elseif s.lastcmdkey == GLFW.KEY_L
         println("User wants to turn right")
         turn_right(robot)
      elseif s.lastcmdkey == GLFW.KEY_I
         println("User wants to increase tilt")
         increase_pitch(robot)
      elseif s.lastcmdkey == GLFW.KEY_K
         println("User wants to decrease tilt")
         decrease_pitch(robot)
      end
      s.lastcmdkey = nothing
      """
   end
end

# Simulate physics for 1/240 seconds (the default timestep)
function simstep(s::mjSim)
   # Create local simulator d (data), and m (model) variables
   d = s.d
   m = s.m

   if s.robot !== nothing
      # Execute next step in command script
      step_script(s::mjSim, s.robot)

      # Step the controller forward by dt
      run!(s.robot)

      # Apply updated joint angles to sim
      d.ctrl .= unsafe_wrap(Array{Float64,1}, pointer(s.robot.state.joint_angles), 12)

      # If Pupper controller, subtract the l1 joint angles from the l2 joint angles
      # to fake the kinematics of the parallel linkage
      if true  # TODO: verify that the controller is a Pupper quadruped controller
         d.ctrl[[3,6,9,12]] .= d.ctrl[[3,6,9,12]] - d.ctrl[[2,5,8,11]]
      end
   end

   if s.paused
      if s.pert[].active > 0
         mjv_applyPerturbPose(m, d, s.pert, 1)  # move mocap and dynamic bodies
         mj_forward(m, d)
      end
   else
      #slow motion factor: 10x
      factor = s.slowmotion ? 10 : 1

      # advance effective simulation time by 1/refreshrate
      startsimtm = d.d[].time
      starttm = time()
      refreshtm = 1.0/(factor*s.refreshrate)
      updates = refreshtm / m.m[].opt.timestep

      steps = round(Int, round(s.framecount+updates)-s.framecount)
      s.framecount += updates

      for i=1:steps
         # clear old perturbations, apply new
         d.xfrc_applied .= 0.0
         if s.pert[].select > 0
            mjv_applyPerturbPose(m, d, s.pert, 0) # move mocap bodies only
            mjv_applyPerturbForce(m, d, s.pert)
         end

         mj_step(m, d)

         # break on reset
         (d.d[].time < startsimtm) && break
      end
   end
end

"""
    pupper(velocity = 0.4, yaw_rate = 0.0)

Creates a Robot controller with specified initial velocity and yaw_rate
"""
function pupper(velocity = 0.4, yaw_rate = 0.0)
   config = Configuration()
   config.z_clearance = 0.01     # height to pick up each foot during trot

   command = Command([velocity, 0], yaw_rate, crouch_height)
   command.pitch = 0.1

   # Create the robot (controller and controller state)
   Robot(config, command)
end

# Run the simulation
"""
    simulate([s::mjSim[, robot::Robot]])

Run the simulation loop
"""
function simulate(s::mjSim = loadmodel(), robot::Union{Robot, Nothing} = pupper())
    s.robot = robot

   # Loop until the user closes the window
   while !GLFW.WindowShouldClose(s.window)
      simstep(s)
      render(s, s.window)
      GLFW.PollEvents()
   end

   GLFW.DestroyWindow(s.window)

   return
end

"""
    simulate(modelpath::String, width = 0, height = 0, robot = nothing)

Run the simulation loop
"""
function simulate(modelpath::String, width = 0, height = 0, robot = nothing)
   simulate(loadmodel(modelpath, width, height), robot)
end

end
