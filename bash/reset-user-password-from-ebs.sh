#!/bin/bash
# Create variables for input parameters
user_name="{{LinuxUserName}}"
secret_arn="{{SecretArn}}"
volume_id="{{GetInstanceRootVolume.RootDeviceVolumeId}}"
region="{{global:REGION}}"

# If the user name is empty, defaults to "ec2-user"
if [ -z $user_name ]; then user_name="ec2-user"; fi

# Create mount folder
mount_dir="/awssupport"
mkdir -p $mount_dir

partition=""
# Device name used to attach the volume to the instance (See thr 'AttachRootEbsVolumeToHelperInstance' step)
disk="/dev/xvdbf"
if [ "$(fdisk -l "$disk" 2>/dev/null)" ]; then
  partition=$(fdisk -l "$disk" | awk "/Device/,EOF" | grep "/dev/xvd.*Linux" | grep -v boot | cut -d " " -f 1)
else
  disk=""
  for device in /sys/devices/pci*/*/nvme/nvme*/serial; do
    vol=$(echo "$volume_id" | sed 's/-//g')
    if grep "$vol" "$device" >/dev/null 2>&1; then
      parentdir="$(dirname "$device")/uevent"
      disk="$(grep "DEVNAME" "$parentdir" | cut -d "=" -f 2)"
    fi
  done
  partition=$(fdisk -l "$disk" | awk "/Device/,EOF" | grep "/dev/nvme.*Linux" | grep -v boot | cut -d " " -f 1)
fi
echo "Found partition $partition for disk $volume_id"

[ -z "$partition" ] && throw "An error occurred when trying to find the partition for disk $disk"

# Mount the target instance Amazon EBS root volume
mount "$partition" $mount_dir >/dev/null 2>&1 || {
  mount -o nouuid "$partition" $mount_dir >/dev/null 2>&1 || throw "An error occurred when trying to mount the attached volume $volume_id"
}
echo "Attached volume $volume_id with partition $partition mounted successfully"

# Try to get the Secrets Manager secret ARN to test access to the secret
aws secretsmanager get-secret-value --secret-id $secret_arn --region $region --output text --query ARN >/dev/null 2>&1 || throw "An error occurred when trying to get $secret_arn"

# Change the use password using chpasswd
if echo $user_name:$(aws secretsmanager get-secret-value --secret-id $secret_arn --region $region --output text --query SecretString) | chroot $mount_dir /usr/sbin/chpasswd; then
  echo "Password successfully set for $user_name"
  # Unmount the target instance Amazon EBS root volume
  umount $mount_dir >/dev/null 2>&1 || throw "An error occurred when trying to unmount the attached volume $volume_id"
  echo "Attached volume $volume_id unmounted successfully"
  exit 0
else
  echo "An error occurred when trying to set the password for $user_name"
  # Unmount the target instance Amazon EBS root volume
  umount $mount_dir >/dev/null 2>&1 || throw "An error occurred when trying to unmount the attached volume $volume_id"
  exit 1
fi
