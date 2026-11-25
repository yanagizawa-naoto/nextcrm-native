import * as React from "react";

interface EmailTemplateProps {
  firstName: string;
}

export const DemoTemplate: React.FC<Readonly<EmailTemplateProps>> = ({
  firstName,
}) => (
  <div>
    <h1>{"ようこそ、"}{firstName}!</h1>
  </div>
);
