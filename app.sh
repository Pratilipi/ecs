echo "$4***** Running bash app.sh $1 $2 $3 $4 $5"

COMMAND=$1
REALM=$2
STAGE=$3
APP_NAME=$4
APP_VERSION=$5

if [ "$COMMAND" != "build" -a "$COMMAND" != "run" -a "$COMMAND" != "push" -a "$COMMAND" != "create" -a "$COMMAND" != "update" -a "$COMMAND" != "delete" ] || [ "$REALM" != "product" -a "$REALM" != "growth" ] || [ "$STAGE" != "devo" -a "$STAGE" != "gamma" -a "$STAGE" != "prod" ] || [ "$APP_NAME" == "" ] || [ "$APP_VERSION" == "" ]
then
  echo "$APP_NAME***** syntax: bash app.sh <command> <realm> <stage> <app-name> <app-version>"
  exit 1
fi

if [ "$APP_NAME" == "notification" ]
then
  bash ../app-deploy-notification.sh $COMMAND $REALM $STAGE $APP_NAME-daemon $APP_VERSION
  bash ../app-deploy-notification.sh $COMMAND $REALM $STAGE $APP_NAME-worker $APP_VERSION
fi

if [ ! -f "Dockerfile.raw" ]
then
  echo "$APP_NAME***** Could not find Dockerfile.raw !"
  exit 1
fi

if [ ! -f "ecr-task-def.raw" ]
then
  echo "$APP_NAME***** Could not find ecr-task-def.raw !"
  exit 1
fi

replace_dockerfile()
{
  echo "$APP_NAME***** replacing Dockerfile.raw and storing in Dockerfile"
  cat Dockerfile.raw \
  | sed "s#\$DOCKER_REPO#$ECR_REPO#g" \
  | sed "s#\$STAGE#$STAGE#g" \
  > Dockerfile
  echo "$APP_NAME***** created Dockerfile with replaced contents of Dockerfile.raw"
}

build_image()
{
  echo "$APP_NAME***** image: building $ECR_IMAGE"
  $(aws ecr get-login --no-include-email)
  docker build --tag $ECR_IMAGE .
  STATUS=$?
  echo "$APP_NAME***** Deleting Dockerfile"
  rm Dockerfile
  echo "$APP_NAME***** Successfully deleted Dockerfile"
  if [ $STATUS == 0 ]
  then
    echo "$APP_NAME***** image: $ECR_IMAGE built"
  else
    echo "$APP_NAME***** error while builing image: $ECR_IMAGE"
    exit $STATUS
  fi
}

run_image()
{
  echo "$APP_NAME***** image: running $ECR_IMAGE"
  docker run $ECR_IMAGE
  STATUS=$?
  if [ $STATUS == 0 ]
  then
    echo "$APP_NAME***** image: $ECR_IMAGE successfully ran"
  else
    echo "$APP_NAME***** error while running image: $ECR_IMAGE"
    exit $STATUS
  fi
}

create_repo()
{
  REPO_NAMES=$(aws ecr describe-repositories | jq  '.repositories[].repositoryName')

  REPO_CREATED=0

  for REPO_NAME in $REPO_NAMES
  do
   if [ $REPO_NAME == "\"$PREFIX$STAGE/$APP_NAME\"" ]
   then
    echo "$APP_NAME***** repository: $PREFIX$STAGE/$APP_NAME exists."
    REPO_CREATED=1
    break
   fi
  done

  if [ $REPO_CREATED == 0 ]
  then
    echo "$APP_NAME***** creating ecr repository: $PREFIX$STAGE/$APP_NAME"
    aws ecr create-repository --repository-name $PREFIX$STAGE/$APP_NAME >> /dev/null
    STATUS=$?
    if [ $STATUS == 0 ]
    then
      echo "$APP_NAME***** repository: $PREFIX$STAGE/$APP_NAME created."
    else
      echo "$APP_NAME***** error while creating repository: $PREFIX$STAGE/$APP_NAME"
      exit $STATUS
    fi
  fi
}

push_image()
{
  echo "$APP_NAME***** image: pushing $ECR_IMAGE"
  $(aws ecr get-login --no-include-email)
  docker push $ECR_IMAGE

  STATUS=$?
  if [ $STATUS == 0 ]
  then
    echo "$APP_NAME***** image: $ECR_IMAGE pushed."
  else
    echo "$APP_NAME***** error while pushing image: $ECR_IMAGE"
    exit $STATUS
  fi
}

replace_task_def()
{
  echo "$APP_NAME***** replacing ecr-task-def.raw and storing in ecr-task-def.json"
  cat ecr-task-def.raw \
    | sed "s#\$STAGE#$STAGE#g" \
    | sed "s#\$PREFIX#$PREFIX#g" \
    | sed "s#\$DOCKER_REPO#$ECR_REPO#g" \
    | sed "s#\$APP_NAME#$APP_NAME#g" \
    | sed "s#\$APP_VERSION#$APP_VERSION#g" \
    | sed "s#\$AWS_PROJ_ID#$AWS_PROJ_ID#g" \
    > ecr-task-def.json
  echo "$APP_NAME***** created ecr-task-def.json with replaced contents of ecr-task-def.raw"
}

register_task_def()
{
  echo "$APP_NAME***** registering ecr-task-def.json"
  TASK_DEF_VER=$(aws ecs register-task-definition --cli-input-json file://ecr-task-def.json | jq -r '.taskDefinition.revision')
  STATUS=$?
  echo "$APP_NAME***** Deleting ecr-task-def.json"
  rm ecr-task-def.json
  echo "$APP_NAME***** Successfully deleted ecr-task-def.json"
  if [ $STATUS == 0 ]
  then
    echo "$APP_NAME***** task-def: $APP_NAME registered."
  else
    echo "$APP_NAME***** error while registering task-def: $APP_NAME"
    exit $STATUS
  fi
}

create_log()
{
  echo "$APP_NAME***** logs: creating $PREFIX$STAGE-$APP_NAME"
  aws logs create-log-group --log-group-name $PREFIX$STAGE-$APP_NAME
  STATUS=$?
  if [ $STATUS == 0 ]
  then
    echo "$APP_NAME***** logs: $PREFIX$STAGE-$APP_NAME created."
  else
    echo "$APP_NAME***** error while creating logs: $PREFIX$STAGE-$APP_NAME"
    exit $STATUS
  fi

  RETENTION_IN_DAYS=7
  if [ $STAGE == "devo" ]
  then
    RETENTION_IN_DAYS=1
  fi
  
  echo "$APP_NAME***** logs: setting retention-in-days as $RETENTION_IN_DAYS for $PREFIX$STAGE-$APP_NAME"
  aws logs put-retention-policy --log-group-name $PREFIX$STAGE-$APP_NAME --retention-in-days $RETENTION_IN_DAYS
  STATUS=$?
  if [ $STATUS == 0 ]
  then
    echo "$APP_NAME***** logs: $PREFIX$STAGE-$APP_NAME retention-in-days set to $RETENTION_IN_DAYS."
  else
    echo "$APP_NAME***** error while setting retention-in-days for logs: $PREFIX$STAGE-$APP_NAME"
    exit $STATUS
  fi
}

create_target()
{
  echo ... started creating target group
  echo AWS Response:
  echo "****************************************************************"
  TARGET_GRP=$(aws elbv2 create-target-group \
    --name ecs-$PREFIX$STAGE-$APP_NAME-tg \
    --protocol HTTP \
    --port 80 \
    --vpc-id $VPC_ID \
    --health-check-protocol HTTP \
    --health-check-path /health \
    --health-check-interval-seconds 30 \
    --health-check-timeout-seconds 5 \
    --healthy-threshold-count 5 \
    --unhealthy-threshold-count 2 \
    --matcher HttpCode=200)
  echo $TARGET_GRP
  echo "****************************************************************"
  TARGET_GRP_ARN=$(echo $TARGET_GRP | jq -r '.TargetGroups[0]["TargetGroupArn"]')
  echo ... created target group: $TARGET_GRP_ARN
}

add_target_to_ilb()
{
  echo ... started adding target group to the internal load balancer
  echo AWS Response:
  echo "****************************************************************"
  aws elbv2 create-rule \
    --listener-arn $LB_LISTNER \
    --priority $(date +%M)$(date +%H) \
    --conditions Field=path-pattern,Values=\'/$APP_NAME/*\' \
    --actions Type=forward,TargetGroupArn=$TARGET_GRP_ARN
  echo "****************************************************************"
  echo ... added target group to the internal load balancer
}

create_service()
{
  echo ... started creating service
  echo AWS response:
  echo "****************************************************************"
  aws ecs create-service \
    --cluster $PREFIX$STAGE-ecs \
    --service-name $APP_NAME \
    --task-definition $APP_NAME:$TASK_DEF_VER \
    --role ecsServiceRole \
    --load-balancers targetGroupArn=$TARGET_GRP_ARN,containerName=$APP_NAME,containerPort=80 \
    --placement-strategy type="spread",field="instanceId" \
    --desired-count 1
  echo "****************************************************************"
  echo ... created service: $APP_NAME
}

update_service()
{
  echo "$APP_NAME***** service: updating $APP_NAME."
  aws ecs update-service \
    --cluster $PREFIX$STAGE-ecs \
    --service $APP_NAME \
    --task-definition $APP_NAME:$TASK_DEF_VER
  STATUS=$?
  if [ $STATUS == 0 ]
  then
    echo "$APP_NAME***** service: $APP_NAME updated."
  else
    echo "$APP_NAME***** error while updating service: $APP_NAME"
    exit $STATUS
  fi
}

autoscaling_alarm()
{
  if [ $STAGE == "prod" ]
  then
    aws application-autoscaling register-scalable-target \
      --resource-id service/$PREFIX$STAGE-ecs/$APP_NAME \
      --service-namespace ecs \
      --scalable-dimension ecs:service:DesiredCount \
      --min-capacity 2 \
      --max-capacity 100 \
      --role-arn $AUTO_SCALING_IAM_ROLE >> /dev/null 2>&1

    SCALING_POLICY_ARN=$(aws application-autoscaling put-scaling-policy \
      --policy-name ecs-$PREFIX$STAGE-$APP_NAME-scaleup-cpu \
      --service-namespace ecs \
      --resource-id service/$PREFIX$STAGE-ecs/$APP_NAME \
      --scalable-dimension ecs:service:DesiredCount \
      --policy-type StepScaling \
      --step-scaling-policy-configuration "AdjustmentType=ChangeInCapacity,StepAdjustments=[{MetricIntervalLowerBound=0.0,ScalingAdjustment=1}],Cooldown=300,MetricAggregationType=Average" \
      | jq -r '.PolicyARN')

    aws cloudwatch put-metric-alarm \
      --alarm-name ecs-$PREFIX$STAGE-$APP_NAME-cpu80-hi \
      --alarm-description "ECS CPU utilization for $APP_NAME service is greater than 80% for 2 minutes" \
      --metric-name CPUUtilization \
      --namespace AWS/ECS \
      --statistic Average \
      --period 60 \
      --threshold 80 \
      --comparison-operator GreaterThanThreshold \
      --dimensions Name="ServiceName",Value="$APP_NAME" Name="ClusterName",Value="$PREFIX$STAGE-ecs" \
      --evaluation-periods 2 \
      --treat-missing-data missing \
      --alarm-actions $SNS_RESOURCE $SCALING_POLICY_ARN >> /dev/null 2>&1

    SCALING_POLICY_ARN=$(aws application-autoscaling put-scaling-policy \
      --policy-name ecs-$PREFIX$STAGE-$APP_NAME-scaledown-cpu \
      --service-namespace ecs \
      --resource-id service/$PREFIX$STAGE-ecs/$APP_NAME \
      --scalable-dimension ecs:service:DesiredCount \
      --policy-type StepScaling \
      --step-scaling-policy-configuration "AdjustmentType=ChangeInCapacity,StepAdjustments=[{MetricIntervalUpperBound=0.0,ScalingAdjustment=-1}],Cooldown=300,MetricAggregationType=Average" \
      | jq -r '.PolicyARN')

    aws cloudwatch put-metric-alarm \
      --alarm-name ecs-$PREFIX$STAGE-$APP_NAME-cpu40-lo \
      --alarm-description "ECS CPU utilization for $APP_NAME service is less than 40% for 10 minutes" \
      --metric-name CPUUtilization \
      --namespace AWS/ECS \
      --statistic Average \
      --period 60 \
      --threshold 40 \
      --comparison-operator LessThanThreshold \
      --dimensions Name="ServiceName",Value="$APP_NAME" Name="ClusterName",Value="$PREFIX$STAGE-ecs" \
      --evaluation-periods 10 \
      --treat-missing-data missing \
      --alarm-actions $SNS_RESOURCE $SCALING_POLICY_ARN >> /dev/null 2>&1

    SCALING_POLICY_ARN=$(aws application-autoscaling put-scaling-policy \
      --policy-name ecs-$PREFIX$STAGE-$APP_NAME-scaleup-burst \
      --service-namespace ecs \
      --resource-id service/$PREFIX$STAGE-ecs/$APP_NAME \
      --scalable-dimension ecs:service:DesiredCount \
      --policy-type StepScaling \
      --step-scaling-policy-configuration "AdjustmentType=ChangeInCapacity,StepAdjustments=[{MetricIntervalLowerBound=0.0,ScalingAdjustment=10}],Cooldown=300,MetricAggregationType=Average" \
      | jq -r '.PolicyARN')

    aws cloudwatch put-metric-alarm \
      --alarm-name ecs-$PREFIX$STAGE-$APP_NAME-cpu100-hi \
      --alarm-description "ECS CPU utilization for $APP_NAME service is 100% for 15 minutes" \
      --metric-name CPUUtilization \
      --namespace AWS/ECS \
      --statistic Average \
      --period 60 \
      --threshold 100 \
      --comparison-operator GreaterThanOrEqualToThreshold \
      --dimensions Name="ServiceName",Value="$APP_NAME" Name="ClusterName",Value="$PREFIX$STAGE-ecs" \
      --evaluation-periods 15 \
      --treat-missing-data missing \
      --alarm-actions $SNS_RESOURCE $SCALING_POLICY_ARN >> /dev/null 2>&1

    SCALING_POLICY_ARN=$(aws application-autoscaling put-scaling-policy \
      --policy-name ecs-$PREFIX$STAGE-$APP_NAME-scaleup-mem \
      --service-namespace ecs \
      --resource-id service/$PREFIX$STAGE-ecs/$APP_NAME \
      --scalable-dimension ecs:service:DesiredCount \
      --policy-type StepScaling \
      --step-scaling-policy-configuration "AdjustmentType=ChangeInCapacity,StepAdjustments=[{MetricIntervalLowerBound=0.0,ScalingAdjustment=1}],Cooldown=300,MetricAggregationType=Average" \
      | jq -r '.PolicyARN')

    aws cloudwatch put-metric-alarm \
      --alarm-name ecs-$PREFIX$STAGE-$APP_NAME-memory90-hi \
      --alarm-description "ECS memory utilization for $APP_NAME service is more than 90% for 5 minutes" \
      --metric-name MemoryUtilization \
      --namespace AWS/ECS \
      --statistic Average \
      --period 60 \
      --threshold 90 \
      --comparison-operator GreaterThanThreshold \
      --dimensions Name="ServiceName",Value="$APP_NAME" Name="ClusterName",Value="$PREFIX$STAGE-ecs" \
      --evaluation-periods 5 \
      --treat-missing-data missing \
      --alarm-actions $SNS_RESOURCE $SCALING_POLICY_ARN >> /dev/null 2>&1

    echo ... service autoscaling rules and alarms created: $APP_NAME
  fi
}

if [ $REALM == "growth" ]
then
  PREFIX="gr-"
  if [ $STAGE == "devo" ]
  then
    LB_LISTNER="arn:aws:elasticloadbalancing:ap-southeast-1:381780986962:listener/app/devo-lb-pvt/9063c6c4e264ea17/b144bca497a9a1aa"
  elif [ $STAGE == "gamma" ]
  then
    LB_LISTNER="arn:aws:elasticloadbalancing:ap-southeast-1:370531249777:listener/app/gamma-lb-pvt/98bfeb8d67ee2d26/e0d977e1084f2f2a"
  elif [ $STAGE == "prod" ]
  then
    LB_LISTNER="arn:aws:elasticloadbalancing:ap-southeast-1:370531249777:listener/app/prod-lb-pvt/bfbfa36e82445261/3e3a1b93ec7d49e1"
  fi
else
  PREFIX=""
  if [ $STAGE == "devo" ]
  then
    LB_LISTNER="arn:aws:elasticloadbalancing:ap-southeast-1:381780986962:listener/app/devo-lb-pvt/9063c6c4e264ea17/33322206f52c31c4"
  elif [ $STAGE == "gamma" ]
  then
    LB_LISTNER="arn:aws:elasticloadbalancing:ap-southeast-1:370531249777:listener/app/gamma-lb-pvt/98bfeb8d67ee2d26/a854c15563502db0"
  elif [ $STAGE == "prod" ]
  then
    LB_LISTNER="arn:aws:elasticloadbalancing:ap-southeast-1:370531249777:listener/app/prod-lb-pvt/bfbfa36e82445261/0104e43e491b57f8"
  fi
fi

if [ $STAGE == "devo" ]
then
  AWS_PROJ_ID="381780986962"
  VPC_ID="vpc-662a5602"
  SNS_RESOURCE="arn:aws:sns:ap-southeast-1:381780986962:devo-ecs-asg-sns"
  AUTO_SCALING_IAM_ROLE="arn:aws:iam::381780986962:role/autoscaling_ecs"
elif [ $STAGE == "gamma" ]
then
  AWS_PROJ_ID="370531249777"
  VPC_ID="vpc-c13c7da5"
  SNS_RESOURCE="arn:aws:sns:ap-southeast-1:370531249777:gamma-ecs-asg-sns"
  AUTO_SCALING_IAM_ROLE="arn:aws:iam::370531249777:role/ecsAutoscaleRole"
elif [ $STAGE == "prod" ]
then
  AWS_PROJ_ID="370531249777"
  VPC_ID="vpc-c13c7da5"
  SNS_RESOURCE="arn:aws:sns:ap-southeast-1:370531249777:prod-ecs-asg-sns"
  AUTO_SCALING_IAM_ROLE="arn:aws:iam::370531249777:role/ecsAutoscaleRole"
fi

# TODO: Error out if project id != $AWS_PROJ_ID

ECR_REPO=$AWS_PROJ_ID.dkr.ecr.ap-southeast-1.amazonaws.com/$PREFIX$STAGE
ECR_IMAGE=$ECR_REPO/$APP_NAME:$APP_VERSION



if [ $COMMAND == "build" ]
then
  echo "$APP_NAME***** executing $COMMAND $REALM $STAGE $APP_NAME $APP_VERSION"
  replace_dockerfile
  build_image
elif [ $COMMAND == "run" ]
then
  echo "$APP_NAME***** executing $COMMAND $REALM $STAGE $APP_NAME $APP_VERSION"
  replace_dockerfile
  build_image
  run_image
elif [ $COMMAND == "push" ]
then
  echo "$APP_NAME***** executing $COMMAND $REALM $STAGE $APP_NAME $APP_VERSION"
  replace_dockerfile
  build_image
  create_repo
  push_image
  replace_task_def
  register_task_def
elif [ $COMMAND == "create" ]
then
  echo "$APP_NAME***** executing $COMMAND $REALM $STAGE $APP_NAME $APP_VERSION"
  replace_dockerfile
  build_image
  create_repo
  push_image
  replace_task_def
  register_task_def
  create_log
  create_target
  add_target_to_ilb
  create_service
#  autoscaling_alarm
elif [ $COMMAND == "update" ]
then
  echo "$APP_NAME***** executing $COMMAND $REALM $STAGE $APP_NAME $APP_VERSION"
  replace_dockerfile
  build_image
  create_repo
  push_image
  replace_task_def
  register_task_def
  update_service
elif [ $COMMAND == "delete" ]
then
  echo "$APP_NAME***** executing $COMMAND $REALM $STAGE $APP_NAME $APP_VERSION"
  echo "$APP_NAME***** service: updating $APP_NAME."
  aws ecs update-service --cluster $PREFIX$STAGE-ecs --service $APP_NAME --desired-count 0
  echo "$APP_NAME***** service: $APP_NAME updated."
  echo "$APP_NAME***** service: deleting $APP_NAME."
  aws ecs delete-service --cluster $PREFIX$STAGE-ecs --service $APP_NAME
  echo "$APP_NAME***** service: $APP_NAME deleted."
fi

echo "$APP_NAME***** app.sh $1 $2 $3 $4 $5 SUCCESS"
