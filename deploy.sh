#!/bin/bash

export AWS_PAGER=""
set -e

# ==============================================================================
# CONFIGURACIÓN
# ==============================================================================
export AWS_REGION="us-east-1"
export ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
export REPO="null-trade"
export CLUSTER="null-trade-cluster"
export APP_SVC="null-trade-svc"

# ==============================================================================
# VALIDACIONES DE PRERREQUISITOS
# ==============================================================================
echo "==> Validando prerrequisitos..."

if ! command -v aws &> /dev/null; then
    echo "ERROR: aws CLI no esta instalado. Instalalo y ejecuta: aws configure"
    exit 1
fi

if ! command -v docker &> /dev/null; then
    echo "ERROR: Docker no esta instalado. Instalalo desde: https://docs.docker.com/get-docker/"
    exit 1
fi

if ! docker info &> /dev/null; then
    echo "ERROR: El daemon de Docker no esta corriendo. Inicialo con: sudo systemctl start docker"
    exit 1
fi

if ! docker image inspect null-trade:1.0 &> /dev/null; then
    echo "ERROR: La imagen 'null-trade:1.0' no existe localmente."
    echo ""
    echo "Ejecuta desde este directorio:"
    echo "  docker build -t null-trade:1.0 ."
    echo "  docker run --rm -p 8080:80 null-trade:1.0"
    echo "  # Verifica en http://localhost:8080, luego Ctrl+C"
    exit 1
fi

ACCOUNT_TEST=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
if [ -z "$ACCOUNT_TEST" ] || [ "$ACCOUNT_TEST" = "None" ]; then
    echo "ERROR: No se pudieron verificar las credenciales de AWS. Ejecuta: aws configure"
    exit 1
fi

echo "    AWS CLI: OK"
echo "    Docker: OK"
echo "    Imagen null-trade:1.0: OK"
echo "    Credenciales AWS: OK (Cuenta: $ACCOUNT)"
echo ""

# ==============================================================================
# 1. RED (VPC, SUBREDES, INTERNET GATEWAY, ROUTING)
# ==============================================================================
echo "==> 1. Creando la VPC..."
export VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --query 'Vpc.VpcId' --output text)
aws ec2 create-tags --resources $VPC_ID --tags Key=Name,Value=null-trade-vpc

echo "==> 2. Creando Subred 1 (us-east-1a)..."
export SUBNET_1=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.1.0/24 --availability-zone ${AWS_REGION}a --query 'Subnet.SubnetId' --output text)

echo "==> 3. Creando Subred 2 (us-east-1b)..."
export SUBNET_2=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.2.0/24 --availability-zone ${AWS_REGION}b --query 'Subnet.SubnetId' --output text)

echo "==> 4. Creando y conectando el Internet Gateway..."
export IGW_ID=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID

echo "==> 5. Configurando la Tabla de Enrutamiento Pública..."
export ROUTE_TABLE_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id $ROUTE_TABLE_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
aws ec2 associate-route-table --subnet-id $SUBNET_1 --route-table-id $ROUTE_TABLE_ID > /dev/null
aws ec2 associate-route-table --subnet-id $SUBNET_2 --route-table-id $ROUTE_TABLE_ID > /dev/null

echo "==> 6. Habilitando DNS hostnames en la VPC..."
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames

echo "==> 7. Habilitando auto-assign public IP en las subredes..."
aws ec2 modify-subnet-attribute --subnet-id $SUBNET_1 --map-public-ip-on-launch
aws ec2 modify-subnet-attribute --subnet-id $SUBNET_2 --map-public-ip-on-launch

echo "==> 8. Creando el Security Group (HTTP puerto 80)..."
export SG_ID=$(aws ec2 create-security-group --group-name "null-trade-sg" --description "Permitir HTTP puerto 80" --vpc-id $VPC_ID --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 80 --cidr 0.0.0.0/0

# ==============================================================================
# 2. ROL IAM PARA ECS
# ==============================================================================
echo "==> 9. Creando rol de ejecución ecsTaskExecutionRole..."
aws iam create-role --role-name ecsTaskExecutionRole --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}' 2>/dev/null || true
aws iam attach-role-policy --role-name ecsTaskExecutionRole --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy 2>/dev/null || true

# ==============================================================================
# 3. PUBLICACIÓN EN AMAZON ECR
# ==============================================================================
echo "==> 10. Creando repositorio en Amazon ECR..."
aws ecr create-repository --repository-name $REPO --region $AWS_REGION 2>/dev/null || true

echo "==> 11. Autenticando Docker con ECR..."
aws ecr get-login-password --region $AWS_REGION \
  | docker login --username AWS --password-stdin $ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com

export IMG="$ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com/$REPO:1.0"

echo "==> 12. Subiendo la imagen Docker de null-trade..."
docker tag null-trade:1.0 $IMG
docker push $IMG

# ==============================================================================
# 4. BALANCEADOR DE CARGA (ALB)
# ==============================================================================
echo "==> 13. Creando Target Group (tipo IP para Fargate)..."
export TG_ARN=$(aws elbv2 create-target-group \
  --name null-trade-tg \
  --protocol HTTP \
  --port 80 \
  --vpc-id $VPC_ID \
  --target-type ip \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text)

echo "==> 14. Creando Application Load Balancer..."
export ALB_ARN=$(aws elbv2 create-load-balancer \
  --name null-trade-alb \
  --subnets $SUBNET_1 $SUBNET_2 \
  --security-groups $SG_ID \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text)

echo "Esperando a que el ALB esté disponible..."
sleep 15

echo "==> 15. Creando Listener en el ALB (puerto 80)..."
aws elbv2 create-listener \
  --load-balancer-arn $ALB_ARN \
  --protocol HTTP \
  --port 80 \
  --default-actions Type=forward,TargetGroupArn=$TG_ARN

# ==============================================================================
# 5. DESPLIEGUE EN AMAZON ECS / FARGATE
# ==============================================================================
echo "==> 16. Creando el clúster ECS..."
aws ecs create-cluster --cluster-name $CLUSTER --capacity-providers FARGATE

echo "==> 17. Escribiendo la Task Definition..."
cat << EOF > taskdef.json
{
  "family": "$REPO",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "arn:aws:iam::$ACCOUNT:role/ecsTaskExecutionRole",
  "containerDefinitions": [
    {
      "name": "web",
      "image": "$IMG",
      "portMappings": [{"containerPort": 80}]
    }
  ]
}
EOF

echo "==> 18. Registrando la Task Definition..."
aws ecs register-task-definition --cli-input-json file://taskdef.json

echo "==> 19. Creando el Servicio ECS (2 tareas, Multi-AZ)..."
aws ecs create-service \
  --cluster $CLUSTER \
  --service-name $APP_SVC \
  --task-definition $REPO \
  --desired-count 2 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_1,$SUBNET_2],securityGroups=[$SG_ID],assignPublicIp=ENABLED}" \
  --load-balancers "targetGroupArn=$TG_ARN,containerName=web,containerPort=80"

echo ""
echo "=============================================================================="
echo " DESPLIEGUE COMPLETADO"
echo " Espera ~5 minutos y luego accede a:"
echo ""
ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN --query 'LoadBalancers[0].DNSName' --output text)
echo " http://$ALB_DNS"
echo "=============================================================================="