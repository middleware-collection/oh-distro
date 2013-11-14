'''
Created on Nov 13, 2013

@author: Twan, Maurice
'''

import time

import rospy
from handle_msgs.msg import HandleControl
from handle_msgs.msg import HandleSensors

from IRobotHandConfigParser import IRobotHandConfigParser


motor_indices = range(3)

# found using find_calibration_pose.
# standard deviations: {0: 48.75612781999817, 1: 36.558993421591907, 2: 27.37243138634199}
jig_pose = {0: 8170.8000000000002, 1: 7925.8000000000002, 2: 8406.5}

# standard deviations: {0: 59.872865306414063, 1: 110.36235771312609, 2: 80.058728443561989}
no_jig_pose = {0: 8990.7999999999993, 1: 8931.5, 2: 9428.0}

def set_command_message_same_value(command_message, control_type, motor_indices, value):
    values = dict((motor_index, value) for motor_index in motor_indices)
    set_command_message(command_message, control_type, values)

def set_command_message(command_message, control_type, values):
    for motor_index in values.keys():
        command_message.valid[motor_index] = True
        command_message.type[motor_index] = control_type
        command_message.value[motor_index] = values[motor_index]

def loop_control(publisher, rate, max_time, control):
    start_time = rospy.get_time()

    while rospy.get_time() - start_time < max_time and not rospy.is_shutdown():
        command_message = HandleControl()
        control(command_message)
        publisher.publish(command_message)
        rate.sleep()

class IRobotHandController(object):

    def __init__(self, side):
        self.sensors = HandleSensors()
        self.config_parser = IRobotHandConfigParser(side)
        self.config_parser.load()
    
        node_name = "mit_irobot_hand_control"
        publisher_name = "control"
        subscriber_name = "sensors/raw"
        ros_rate = 100.0  # todo: something smarter
        
        rospy.init_node(node_name)
        self.rate = rospy.Rate(ros_rate)
        self.publisher = rospy.Publisher(publisher_name, HandleControl)
        self.subscriber = rospy.Subscriber(subscriber_name, HandleSensors, self.sensor_data_callback)
        self.sensor_data_listeners = []

    def add_sensor_data_listener(self, listener):
        self.sensor_data_listeners.append(listener)

    def remove_sensor_data_listener(self, listener):
        self.sensor_data_listeners.remove(listener)

    def sensor_data_callback(self, data):
        self.sensors = data
        for listener in self.sensor_data_listeners:
            listener.notify(data, rospy.get_time())

    def zero_current(self):
        no_current_message = HandleControl()
        set_command_message_same_value(no_current_message, HandleControl.CURRENT, motor_indices, 0)
        self.publisher.publish(no_current_message)

    def close_hand_current_control(self, finger_close_current):
        grasp_time = 5
        def control(command_message):
            set_command_message_same_value(command_message, HandleControl.CURRENT, motor_indices, finger_close_current)
    
        loop_control(self.publisher, self.rate, grasp_time, control)
    
    def open_hand_angle_control(self):
        open_time = 5
        open_angle = 10
        def control(command_message):
            set_command_message_same_value(command_message, HandleControl.ANGLE, motor_indices, open_angle)
            
        loop_control(self.publisher, self.rate, open_time, control)
    
    def open_hand_motor_excursion_control(self):
        open_hand_desired = 2000
        open_time = 5
        open_hand_desireds = dict((motor_index, open_hand_desired) for motor_index in motor_indices)
        self.motor_excursion_control_loop(open_hand_desireds, open_time)

    def motor_excursion_control_loop(self, open_hand_desireds, duration):
        def control(command_message):
            self.motor_excursion_control(command_message, open_hand_desireds)
        loop_control(self.publisher, self.rate, duration, control)

    def motor_excursion_control(self, command_message, open_hand_desireds):
        motor_indices = open_hand_desireds.keys()
        offsets = dict((i, self.config_parser.get_motor_encoder_offset(i)) for i in motor_indices)
        desireds_with_offset = dict((i, open_hand_desireds[i] + offsets[i]) for i in motor_indices)
        set_command_message(command_message, HandleControl.POSITION, desireds_with_offset)

    def clear_config(self):
        self.config_parser.clear()

    @staticmethod
    def get_motor_indices():
        return motor_indices

    def calibrate_motor_encoder_offsets(self, in_jig):
        
        if in_jig:
            calibration_pose = jig_pose
        else:
            calibration_pose = no_jig_pose

        print "Calibrating: closing hand"
        self.close_hand_current_control(300)

        wait_time = 2
        time.sleep(wait_time)

        print "Calibrating: setting offsets"
        for motor_index in motor_indices:
            current_value = self.sensors.motorHallEncoder[motor_index]
            offset = current_value - calibration_pose[motor_index]
            self.config_parser.set_motor_encoder_offset(motor_index, offset)
        self.zero_current()

    def exit(self):
        self.config_parser.save()