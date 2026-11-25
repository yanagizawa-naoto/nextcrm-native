import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { crm_Opportunities } from "@prisma/client";
import {
  CalendarDays,
  ClipboardList,
  CoinsIcon,
  Combine,
  File,
  Globe,
  Globe2,
  Landmark,
  List,
  Percent,
  Phone,
  SquareStack,
  Text,
  User,
} from "lucide-react";
import moment from "moment";
import { Clapperboard, Tags } from "lucide-react";
import { prismadb } from "@/lib/prisma";
import Link from "next/link";
import { EnvelopeClosedIcon, LightningBoltIcon } from "@radix-ui/react-icons";
import { LucideLandmark } from "lucide-react";
import { AccountDetailActions } from "./AccountDetailActions";

interface OppsViewProps {
  data: any;
}

export async function BasicView({ data }: OppsViewProps) {
  //console.log(data, "data");
  const users = await prismadb.users.findMany();
  if (!data) return <div>{"商談が見つかりません"}</div>;
  return (
    <div className="pb-3 space-y-5">
      {/*      <pre>{JSON.stringify(data, null, 2)}</pre> */}
      <Card>
        <CardHeader className="pb-3">
          <div className="flex w-full justify-between">
            <div>
              <CardTitle>{data.name}</CardTitle>
              <CardDescription>{"ID："}{data.id}</CardDescription>
            </div>
            <div>
              <AccountDetailActions account={data} />
            </div>
          </div>
        </CardHeader>
        <CardContent>
          <div className="grid grid-cols-2 w-full gap-5 ">
            <div>
              <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
                <CoinsIcon className="mt-px h-5 w-5" />
                <div className="space-y-1">
                  <p className="text-sm font-medium leading-none">
                    {"年間売上高"}</p>
                  <p className="text-sm text-muted-foreground">
                    {data.annual_revenue}
                  </p>
                </div>
              </div>
              <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
                <Landmark className="mt-px h-5 w-5" />
                <div className="space-y-1">
                  <p className="text-sm font-medium leading-none">{"法人番号・登録番号"}</p>
                  <p className="text-sm text-muted-foreground">
                    {data.company_id}
                  </p>
                </div>
              </div>
              <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
                <Percent className="mt-px h-5 w-5" />
                <div className="space-y-1">
                  <p className="text-sm font-medium leading-none">{"税務登録番号"}</p>
                  <p className="text-sm text-muted-foreground">
                    {data.vat ? data.vat : "未割り当て"}
                  </p>
                </div>
              </div>
              <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
                <Tags className="mt-px h-5 w-5" />
                <div className="space-y-1">
                  <p className="text-sm font-medium leading-none">{"価格表"}</p>
                  <p className="text-sm text-muted-foreground">
                    {data.pricelist?.name ?? "既定"}
                  </p>
                </div>
              </div>
              <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
                <File className="mt-px h-5 w-5" />
                <div className="space-y-1">
                  <p className="text-sm font-medium leading-none">
                    {"品名・内容"}</p>
                  <p className="text-sm text-muted-foreground">
                    {data.description}
                  </p>
                </div>
              </div>
              <div className="-mx-2 flex items-start justify-between space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
                <div className="flex mt-px gap-5">
                  <EnvelopeClosedIcon className="mt-px h-5 w-5" />
                  <div className="space-y-1">
                    <p className="text-sm font-medium leading-none">{"メールアドレス"}</p>

                    <Link
                      href={`mailto:${data.email}`}
                      className="flex items-center  gap-5 text-sm text-muted-foreground"
                    >
                      {data.email}
                      <EnvelopeClosedIcon />
                    </Link>
                  </div>
                </div>
                <p className="pr-20"></p>
              </div>
              <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
                <Globe2 className="mt-px h-5 w-5" />
                <div className="space-y-1">
                  <p className="text-sm font-medium leading-none">{"ウェブサイト"}</p>
                  <p className="text-sm text-muted-foreground">
                    {data?.website ? (
                      <Link href={data.website}>{data.website}</Link>
                    ) : (
                      "N/A"
                    )}
                  </p>
                </div>
              </div>
              <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
                <Phone className="mt-px h-5 w-5" />
                <div className="space-y-1">
                  <p className="text-sm font-medium leading-none">
                    {"会社電話番号"}</p>
                  <p className="text-sm text-muted-foreground">
                    {data.office_phone}
                  </p>
                </div>
              </div>
              <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
                <CoinsIcon className="mt-px h-5 w-5" />
                <div className="space-y-1">
                  <p className="text-sm font-medium leading-none">{"FAX番号"}</p>
                  <p className="text-sm text-muted-foreground">{data.fax}</p>
                </div>
              </div>
            </div>
            <div>
              <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
                <User className="mt-px h-5 w-5" />
                <div className="space-y-1">
                  <p className="text-sm font-medium leading-none">
                    {"担当者"}</p>
                  <p className="text-sm text-muted-foreground">
                    {data.assigned_to_user?.name ?? "未割り当て"}
                  </p>
                </div>
              </div>
              <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
                <CalendarDays className="mt-px h-5 w-5" />
                <div className="space-y-1">
                  <p className="text-sm font-medium leading-none">{"作成"}</p>
                  <p className="text-sm text-muted-foreground">
                    {moment(data.created_on).format("YYYY年M月D日")}
                  </p>
                </div>
                <div className="space-y-1">
                  <p className="text-sm font-medium leading-none">{"作成者"}</p>
                  <p className="text-sm text-muted-foreground">
                    {users.find((user) => user.id === data.createdBy)?.name}
                  </p>
                </div>
              </div>
              <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
                <CalendarDays className="mt-px h-5 w-5" />
                <div className="space-y-1">
                  <p className="text-sm font-medium leading-none">
                    {"最終更新日"}</p>
                  <p className="text-sm text-muted-foreground">
                    {moment(data.updatedAt).format("YYYY年M月D日")}
                  </p>
                </div>
                <div className="space-y-1">
                  <p className="text-sm font-medium leading-none">
                    {"最終更新者"}</p>
                  <p className="text-sm text-muted-foreground">
                    {users.find((user) => user.id === data.updatedBy)?.name}
                  </p>
                </div>
              </div>
              <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
                <LightningBoltIcon className="mt-px h-5 w-5" />
                <div className="space-y-1">
                  <p className="text-sm font-medium leading-none">{"状態"}</p>
                  <p className="text-sm text-muted-foreground">{data.status}</p>
                </div>
              </div>
              <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
                <CoinsIcon className="mt-px h-5 w-5" />
                <div className="space-y-1">
                  <p className="text-sm font-medium leading-none">{"種別"}</p>
                  <p className="text-sm text-muted-foreground">{data.type}</p>
                </div>
              </div>
              <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
                <CoinsIcon className="mt-px h-5 w-5" />
                <div className="space-y-1">
                  <p className="text-sm font-medium leading-none">{"所属グループ"}</p>
                  <p className="text-sm text-muted-foreground">
                    {data.member_of}
                  </p>
                </div>
              </div>
              <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
                <CoinsIcon className="mt-px h-5 w-5" />
                <div className="space-y-1">
                  <p className="text-sm font-medium leading-none">{"業種"}</p>
                  <p className="text-sm text-muted-foreground">
                    {data.industry}
                  </p>
                </div>
              </div>
            </div>
          </div>
        </CardContent>
      </Card>
      <div className="grid grid-cols-2 gap-3 w-full">
        <Card>
          <CardHeader className="pb-3">
            <CardTitle>{"請求先住所"}</CardTitle>
          </CardHeader>
          <CardContent className="gap-1">
            <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
              <div className="space-y-1">
                <p className="text-sm font-medium leading-none">
                  {"請求先の町名・番地・建物名"}</p>
                <p className="text-sm text-muted-foreground">
                  {data.billing_street}
                </p>
              </div>
            </div>
            <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
              <div className="space-y-1">
                <p className="text-sm font-medium leading-none">
                  {"請求先の郵便番号"}</p>
                <p className="text-sm text-muted-foreground">
                  {data.billing_postal_code}
                </p>
              </div>
            </div>
            <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
              <div className="space-y-1">
                <p className="text-sm font-medium leading-none">{"請求先の市区町村"}</p>
                <p className="text-sm text-muted-foreground">
                  {data.billing_city}
                </p>
              </div>
            </div>
            <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
              <div className="space-y-1">
                <p className="text-sm font-medium leading-none">
                  {"請求先の都道府県"}</p>
                <p className="text-sm text-muted-foreground">
                  {data.billing_state}
                </p>
              </div>
            </div>
            <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
              <div className="space-y-1">
                <p className="text-sm font-medium leading-none">
                  {"請求先の国"}</p>
                <p className="text-sm text-muted-foreground">
                  {data.billing_country}
                </p>
              </div>
            </div>
          </CardContent>
        </Card>
        <Card>
          <CardHeader className="pb-3">
            <CardTitle>{"送付先住所"}</CardTitle>
          </CardHeader>
          <CardContent className="gap-1">
            <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
              <div className="space-y-1">
                <p className="text-sm font-medium leading-none">
                  {"送付先の町名・番地・建物名"}</p>
                <p className="text-sm text-muted-foreground">
                  {data.shipping_street}
                </p>
              </div>
            </div>
            <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
              <div className="space-y-1">
                <p className="text-sm font-medium leading-none">
                  {"送付先の郵便番号"}</p>
                <p className="text-sm text-muted-foreground">
                  {data.shipping_postal_code}
                </p>
              </div>
            </div>
            <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
              <div className="space-y-1">
                <p className="text-sm font-medium leading-none">
                  {"送付先の市区町村"}</p>
                <p className="text-sm text-muted-foreground">
                  {data.shipping_city}
                </p>
              </div>
            </div>
            <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
              <div className="space-y-1">
                <p className="text-sm font-medium leading-none">
                  {"送付先の都道府県"}</p>
                <p className="text-sm text-muted-foreground">
                  {data.shipping_state}
                </p>
              </div>
            </div>
            <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
              <div className="space-y-1">
                <p className="text-sm font-medium leading-none">
                  {"送付先の国"}</p>
                <p className="text-sm text-muted-foreground">
                  {data.shipping_country}
                </p>
              </div>
            </div>
          </CardContent>
        </Card>
      </div>
    </div>
    /*     <Card>
      <CardHeader className="pb-3">
        <CardTitle>{data.name}</CardTitle>
        <CardDescription>ID:{data.id}</CardDescription>
      </CardHeader>
      <CardContent className="grid grid-cols-2 gap-1">
        <pre>{JSON.stringify(data, null, 2)}</pre>
        <div>
          <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
            
            <div className="space-y-1">
              <p className="text-sm font-medium leading-none">
                Opportunity amount
              </p>
              <p className="text-sm text-muted-foreground">
                {data.budget ? (typeof data.budget === 'bigint' ? data.budget.toString() : data.budget) : "N/A"}
              </p>
            </div>
          </div>

          <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
            <SquareStack className="mt-px h-5 w-5" />
            <div className="space-y-1">
              <p className="text-sm font-medium leading-none">Sales stage</p>
              <p className="text-sm text-muted-foreground"></p>
            </div>
          </div>
          <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
            <Combine className="mt-px h-5 w-5" />
            <div className="space-y-1">
              <p className="text-sm font-medium leading-none">Next step</p>
              <p className="text-sm text-muted-foreground">{data.next_step}</p>
            </div>
          </div>
          <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
            <ClipboardList className="mt-px h-5 w-5" />
            <div className="space-y-1">
              <p className="text-sm font-medium leading-none">Description</p>
              <p className="text-sm text-muted-foreground">
                {data.description}
              </p>
            </div>
          </div>
          <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
            <User className="mt-px h-5 w-5" />
            <div className="space-y-1">
              <p className="text-sm font-medium leading-none">Assigned to</p>
              <p className="text-sm text-muted-foreground">
                {data.assigned_to_user.name}
              </p>
            </div>
          </div>
        </div>
        <div>
          <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
            <Landmark className="mt-px h-5 w-5" />
            <div className="space-y-1">
              <p className="text-sm font-medium leading-none">Account name</p>
              <p className="text-sm text-muted-foreground"></p>
            </div>
          </div>
          <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
            <CalendarDays className="mt-px h-5 w-5" />
            <div className="space-y-1">
              <p className="text-sm font-medium leading-none">
                Expected close date
              </p>
              <p className="text-sm text-muted-foreground">
                {moment(data.close_date).format("YYYY年M月D日")}
              </p>
            </div>
          </div>
          <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
            <CalendarDays className="mt-px h-5 w-5" />
            <div className="space-y-1">
              <p className="text-sm font-medium leading-none">Created</p>
              <p className="text-sm text-muted-foreground">
                {moment(data.created_on).format("YYYY年M月D日")}
              </p>
            </div>
            <div className="space-y-1">
              <p className="text-sm font-medium leading-none">Created by</p>
              <p className="text-sm text-muted-foreground">
                {users.find((user) => user.id === data.created_by)?.name}
              </p>
            </div>
          </div>
          <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
            <CalendarDays className="mt-px h-5 w-5" />
            <div className="space-y-1">
              <p className="text-sm font-medium leading-none">Last update</p>
              <p className="text-sm text-muted-foreground">
                {moment(data.last_activity).format("YYYY年M月D日")}
              </p>
            </div>
            <div className="space-y-1">
              <p className="text-sm font-medium leading-none">Last update by</p>
              <p className="text-sm text-muted-foreground">
                {users.find((user) => user.id === data.last_activity_by)?.name}
              </p>
            </div>
          </div>
          <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
            <List className="mt-px h-5 w-5" />
            <div className="space-y-1">
              <p className="text-sm font-medium leading-none">Type</p>
              <p className="text-sm text-muted-foreground"></p>
            </div>
          </div>
          <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
            <Landmark className="mt-px h-5 w-5" />
            <div className="space-y-1">
              <p className="text-sm font-medium leading-none">Lead source</p>
              <p className="text-sm text-muted-foreground">
                Will be added in the future
              </p>
            </div>
          </div>
          <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
            <Clapperboard className="mt-px h-5 w-5" />
            <div className="space-y-1">
              <p className="text-sm font-medium leading-none">Campaign</p>
              <p className="text-sm text-muted-foreground">
                Will be added in the future
              </p>
            </div>
          </div>
        </div>
      </CardContent>
    </Card> */
  );
}
