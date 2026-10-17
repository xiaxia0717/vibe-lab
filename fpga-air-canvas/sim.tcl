# Vivado 一键仿真脚本（命令行：vivado -mode batch -source sim.tcl）
# 自动建工程、加文件、跑行为级仿真，控制台输出 PASS/FAIL

set proj_dir ./proj_air_canvas

file mkdir $proj_dir
create_project -force air_canvas_sim $proj_dir -part xc7z020clg400-2

add_files -fileset sim_1 color_tracker.v
add_files -fileset sim_1 tb_color_tracker.v

set_property top tb_color_tracker [get_filesets sim_1]
set_property xsim.simulate.runtime 20ms [get_filesets sim_1]

launch_simulation -simset sim_1 -mode behavioral
